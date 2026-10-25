open Core
open Async
open Backtest_shared
module V = Rayforce_ipc.Value
module Wire = Rayforce_ipc.Wire
module Codec = Backtest_reader.Codec
module Sha = Digestif.SHA256

external rename_noreplace : string -> string -> unit = "wb_rename_noreplace"

let invalid message = failwith ("bundle: " ^ message)
let metadata_limit = 16 * 1024 * 1024
let index_limit = 16 * 1024 * 1024
let seal = "workbench-bundle-v1\n"

let read_small path limit =
  Unix.lstat path
  >>= fun stat ->
  if (not (Unix.File_kind.equal stat.kind `File)) || Int64.(stat.size > of_int limit)
  then invalid "metadata/index is not a bounded regular file";
  Reader.file_contents path
  >>| fun contents ->
  if String.length contents > limit then invalid "metadata/index exceeds limit";
  contents
;;

let hash_file path =
  let digest input =
    let bytes = Bytes.create 65536 in
    let rec read context =
      Reader.read input bytes
      >>= function
      | `Eof -> return (Sha.to_hex (Sha.get context))
      | `Ok n -> read (Sha.feed_bytes context ~off:0 ~len:n bytes)
    in
    read (Sha.init ())
  in
  Reader.with_file path ~f:digest
;;

let rec inventory directory prefix =
  Sys.ls_dir directory
  >>= fun names ->
  let visit name =
    let relative = if String.is_empty prefix then name else Filename.concat prefix name in
    let path = Filename.concat directory name in
    Unix.lstat path
    >>= fun stat ->
    match stat.kind with
    | `File -> return [ relative ]
    | `Directory -> inventory path relative
    | _ -> invalid "only regular files/directories are allowed"
  in
  Deferred.List.map names ~how:`Sequential ~f:visit >>| List.concat
;;

let protocol_error = function
  | Protocol.Unsupported_version version -> sprintf "unsupported version %d" version
  | Invalid_request e | Invalid_output e | Io_error e | Unavailable e -> e
  | Busy -> "busy"
  | Cancelled -> "cancelled"
;;

let or_protocol = function
  | Ok x -> x
  | Error error -> invalid (protocol_error error)
;;

let unpack contents =
  if String.length contents < Wire.header_len then invalid "short metadata frame";
  let input = Iobuf.of_string contents in
  let header = Wire.consume_header input in
  if header.payload_len <> Iobuf.length input
  then invalid "metadata frame length mismatch";
  Wire.consume_payload input header
;;

let members = function
  | V.Dict (V.Syms keys, V.List values) when Array.length keys = Array.length values ->
    let pairs =
      Array.to_list
        (Array.map2_exn keys values ~f:(fun key value ->
           Rayforce_ipc.Sym.to_string key, value))
    in
    if List.contains_dup (List.map pairs ~f:fst) ~compare:String.compare
    then invalid "duplicate metadata keys";
    pairs
  | _ -> invalid "metadata must contain dictionaries with list values"
;;

let get fields name =
  match List.Assoc.find fields name ~equal:String.equal with
  | Some v -> v
  | None -> invalid ("missing " ^ name)
;;

let string = function
  | V.String s -> s
  | _ -> invalid "expected string"
;;

let integer = function
  | V.Int n -> n
  | _ -> invalid "expected int64"
;;

let symbols = function
  | V.Syms a -> List.map (Array.to_list a) ~f:Rayforce_ipc.Sym.to_string
  | _ -> invalid "expected symbols"
;;

let dict pairs =
  V.Dict
    ( V.Syms (Array.of_list_map pairs ~f:(fun (s, _) -> Rayforce_ipc.Sym.intern s))
    , V.List (Array.of_list_map pairs ~f:snd) )
;;

let validate_metadata value =
  let fields = members value in
  let version = integer (get fields "version") in
  if not (Int64.equal version 1L) then invalid (sprintf "unsupported version %Ld" version);
  let run = string (get fields "run") in
  if String.is_empty run then invalid "empty run ID";
  let strategies = symbols (get fields "strategies") in
  let payload =
    dict
      [ "metadata", get fields "metadata"
      ; "strategies", get fields "strategies"
      ; "bundle", get fields "details"
      ]
  in
  let info, _ = or_protocol (Codec.decode_run_info ~run payload) in
  let summaries = members (get fields "summaries") in
  let summarize strategy =
    let request =
      { Protocol.id = 0L; generation = 0L; operation = Summary { Model.run; strategy } }
    in
    let reply =
      dict
        [ "version", V.Int 1L
        ; "id", V.Int 0L
        ; "generation", V.Int 0L
        ; "status", V.String "ok"
        ; "payload", get summaries strategy
        ]
    in
    ignore (or_protocol (Codec.decode request reply) : Protocol.reply)
  in
  List.iter strategies ~f:summarize;
  info
;;

let load_metadata directory =
  read_small (Filename.concat directory "metadata.rfn") metadata_limit
  >>| fun contents -> validate_metadata (unpack contents)
;;

let native_args ~service_directory ~directory ~staged =
  [ "-c"
  ; "1"
  ; "-f"
  ; Filename.concat service_directory "open-bundle.rfl"
  ; "--"
  ; "-service"
  ; Filename.concat service_directory "service.rfl"
  ; "-bundle_module"
  ; Filename.concat service_directory "bundle.rfl"
  ; "-directory"
  ; directory
  ]
  @ if staged then [ "-staged"; "yes" ] else []
;;

let files_in_index = function
  | `Assoc fields ->
    (match List.Assoc.find fields "version" ~equal:String.equal with
     | Some (`Int 1) -> ()
     | Some (`Int v) -> invalid (sprintf "unsupported version %d" v)
     | _ -> invalid "invalid index version");
    (match List.Assoc.find fields "files" ~equal:String.equal with
     | Some (`List files) ->
       let entry = function
         | `Assoc [ ("path", `String path); ("sha256", `String digest) ] ->
           let parts = String.split path ~on:'/' in
           if
             String.is_empty path
             || Filename.is_absolute path
             || List.exists parts ~f:(fun p ->
               String.is_empty p || String.equal p "." || String.equal p "..")
             || String.contains path '\\'
             || String.contains path '\000'
             || String.length digest <> 64
             || not (String.for_all digest ~f:Char.is_hex_digit)
           then invalid "invalid checksum entry";
           path, digest
         | _ -> invalid "invalid checksum entry"
       in
       let entries = List.map files ~f:entry in
       if List.contains_dup (List.map entries ~f:fst) ~compare:String.compare
       then invalid "duplicate checksum path";
       entries
     | _ -> invalid "missing checksum list")
  | _ -> invalid "invalid index"
;;

let artifact_files directory =
  inventory directory ""
  >>| fun files ->
  List.filter files ~f:(fun f ->
    not (List.mem [ "checksums.json"; "COMPLETED" ] f ~equal:String.equal))
  |> List.sort ~compare:String.compare
;;

let verify_exn directory =
  read_small (Filename.concat directory "COMPLETED") 64
  >>= fun complete ->
  if not (String.equal complete seal) then invalid "incomplete publication";
  read_small (Filename.concat directory "checksums.json") index_limit
  >>= fun index ->
  let entries = files_in_index (Yojson.Safe.from_string index) in
  artifact_files directory
  >>= fun actual ->
  let expected = List.sort (List.map entries ~f:fst) ~compare:String.compare in
  if
    (not (List.equal String.equal actual expected))
    || not (List.mem actual "metadata.rfn" ~equal:String.equal)
  then invalid "checksum inventory mismatch";
  let check (relative, expected) =
    hash_file (Filename.concat directory relative)
    >>| fun digest ->
    if not (String.equal digest expected) then invalid ("checksum mismatch: " ^ relative)
  in
  Deferred.List.iter entries ~how:`Sequential ~f:check
  >>= fun () -> load_metadata directory
;;

let verify ~directory = Monitor.try_with_or_error (fun () -> verify_exn directory)

let rec remove_tree path =
  Unix.lstat path
  >>= fun stat ->
  match stat.kind with
  | `Directory ->
    Sys.ls_dir path
    >>= fun names ->
    Deferred.List.iter names ~how:`Sequential ~f:(fun name ->
      remove_tree (Filename.concat path name))
    >>= fun () -> Unix.rmdir path
  | _ -> Unix.unlink path
;;

let sync path =
  Unix.openfile path ~mode:[ `Rdonly ]
  >>= fun fd -> Monitor.protect (fun () -> Unix.fsync fd) ~finally:(fun () -> Fd.close fd)
;;

let rec sync_tree path =
  Unix.lstat path
  >>= fun stat ->
  (match stat.kind with
   | `Directory ->
     Sys.ls_dir path
     >>= fun names ->
     Deferred.List.iter names ~how:`Sequential ~f:(fun name ->
       sync_tree (Filename.concat path name))
   | `File -> Deferred.unit
   | _ -> invalid "cannot sync non-regular artifact")
  >>= fun () -> sync path
;;

let write_index directory =
  artifact_files directory
  >>= fun files ->
  let entry relative =
    hash_file (Filename.concat directory relative)
    >>| fun digest -> `Assoc [ "path", `String relative; "sha256", `String digest ]
  in
  Deferred.List.map files ~how:`Sequential ~f:entry
  >>= fun entries ->
  let index =
    Yojson.Safe.to_string (`Assoc [ "version", `Int 1; "files", `List entries ])
  in
  Writer.save (Filename.concat directory "checksums.json") ~contents:index
  >>= fun () -> Writer.save (Filename.concat directory "COMPLETED") ~contents:seal
;;

let publish_cancellable ~cancelled ~directory ~rayforce ~service_directory ~write =
  Monitor.try_with_or_error (fun () ->
    Unix.getcwd ()
    >>= fun cwd ->
    let absolute path =
      if Filename.is_relative path then Filename.concat cwd path else path
    in
    let directory = absolute directory in
    let service_directory = absolute service_directory in
    let parent = Filename.dirname directory in
    Unix.lstat parent
    >>= fun stat ->
    if not (Unix.File_kind.equal stat.kind `Directory)
    then invalid "parent must be a directory";
    Sys.file_exists directory
    >>= fun exists ->
    if not (Poly.equal exists `No) then invalid "destination already exists";
    Unix.mkdtemp (Filename.concat parent ".workbench-staging-XXXXXX")
    >>= fun staging ->
    let published = ref false in
    let cleanup () = if !published then Deferred.unit else remove_tree staging in
    let check_cancelled () = if cancelled () then invalid "publication cancelled" in
    let prepare () =
      check_cancelled ();
      write ~directory:staging
      >>= fun wrote ->
      Or_error.ok_exn wrote;
      check_cancelled ();
      Process.run
        ~prog:rayforce
        ~args:(native_args ~service_directory ~directory:staging ~staged:true)
        ()
      >>= fun native ->
      ignore (Or_error.ok_exn native : string);
      load_metadata staging
      >>= fun info ->
      write_index staging
      >>= fun () ->
      sync_tree staging
      >>= fun () ->
      check_cancelled ();
      In_thread.run (fun () -> rename_noreplace staging directory)
      >>= fun () ->
      published := true;
      sync parent >>| fun () -> info
    in
    Monitor.protect prepare ~finally:cleanup)
;;

let publish ~directory ~rayforce ~service_directory ~write =
  publish_cancellable
    ~cancelled:(fun () -> false)
    ~directory
    ~rayforce
    ~service_directory
    ~write
;;
