open Core
open Async
module Bundle = Backtest_bundle.Bundle

type phase =
  | Running
  | Publishing
  | Completed of Backtest_shared.Model.run_info
  | Failed of string
  | Cancelled

type t =
  { directory : string
  ; mutable phase : phase
  ; mutable logs : string list
  ; mutable process : Process.t option
  ; mutable cancelled : bool
  ; finished : unit Ivar.t
  }

let active t =
  match t.phase with
  | Running | Publishing -> true
  | _ -> false
;;

let log t line = t.logs <- List.take (String.prefix line 2048 :: t.logs) 100

let drain t input =
  Pipe.iter (Reader.lines input) ~f:(fun line ->
    log t line;
    Deferred.unit)
;;

let signal_group process signal =
  Process.run
    ~prog:"kill"
    ~args:[ signal; "--"; "-" ^ Pid.to_string (Process.pid process) ]
    ()
  >>| fun _ -> ()
;;

let stop_process process =
  if Deferred.is_determined (Process.wait process)
  then Deferred.unit
  else
    signal_group process "-TERM"
    >>= fun () ->
    Clock_ns.with_timeout (Time_ns.Span.of_int_sec 2) (Process.wait process)
    >>= function
    | `Result _ -> Deferred.unit
    | `Timeout ->
      signal_group process "-KILL" >>= fun () -> Process.wait process >>| fun _ -> ()
;;

let cancel t =
  if active t && not t.cancelled
  then (
    t.cancelled <- true;
    Option.iter t.process ~f:(fun process -> don't_wait_for (stop_process process)))
;;

let shutdown t =
  cancel t;
  Ivar.read t.finished
;;

let launch
      ~backtest_directory
      ~service_directory
      ~rayforce
      ~strategy
      ~snapshot
      ~output_parent
  =
  let id =
    strategy ^ "-" ^ Int63.to_string (Time_ns.to_int63_ns_since_epoch (Time_ns.now ()))
  in
  let t =
    { directory = Filename.concat output_parent id
    ; phase = Running
    ; logs = []
    ; process = None
    ; cancelled = false
    ; finished = Ivar.create ()
    }
  in
  let write ~directory =
    let args =
      [ Filename.concat backtest_directory "run.sh"
      ; strategy
      ; snapshot
      ; Filename.concat directory "exports"
      ; "-service"
      ; Filename.concat service_directory "service.rfl"
      ; "-bundle_module"
      ; Filename.concat service_directory "bundle.rfl"
      ; "-directory"
      ; directory
      ; "-run_id"
      ; id
      ]
    in
    Process.create
      ~working_dir:backtest_directory
      ~setpgid:Core_unix.Pgid.new_process_group
      ~env:(`Extend [ "RAYFORCE", rayforce ])
      ~prog:"bash"
      ~args
      ()
    >>= fun created ->
    let process = Or_error.ok_exn created in
    t.process <- Some process;
    don't_wait_for (Writer.close (Process.stdin process));
    let stdout = drain t (Process.stdout process)
    and stderr = drain t (Process.stderr process) in
    (if t.cancelled then stop_process process else Deferred.unit)
    >>= fun () ->
    Process.wait process
    >>= fun exited ->
    t.process <- None;
    Deferred.all_unit [ stdout; stderr ]
    >>| fun () ->
    if t.cancelled
    then Or_error.error_string "Run cancelled"
    else (
      match exited with
      | Ok () ->
        t.phase <- Publishing;
        Ok ()
      | Error _ -> Or_error.error_string "Strategy failed; see the run log")
  in
  let work () =
    Unix.mkdir ~p:() output_parent
    >>= fun () ->
    Bundle.publish_cancellable
      ~cancelled:(fun () -> t.cancelled)
      ~directory:t.directory
      ~rayforce
      ~service_directory
      ~write
  in
  let finish result =
    t.phase
    <- (match result with
        | Ok (Ok info) -> Completed info
        | _ when t.cancelled -> Cancelled
        | Ok (Error error) | Error error ->
          log t (Error.to_string_hum error);
          Failed "Run failed; see the run log");
    Ivar.fill_exn t.finished ()
  in
  don't_wait_for (Monitor.try_with_or_error work >>| finish);
  t
;;

let strategies backtest_directory =
  Sys.ls_dir (Filename.concat backtest_directory "strategies")
  >>| fun files ->
  List.filter_map files ~f:(fun file ->
    match String.chop_suffix file ~suffix:".rfl" with
    | Some ("common" | "buyhold") | None -> None
    | Some name -> Some name)
  |> List.sort ~compare:String.compare
;;

let snapshots backtest_directory =
  let root = Filename.concat backtest_directory "data" in
  let valid name =
    let path = Filename.concat root name in
    Deferred.List.for_all [ "SHA256SUMS"; "bars.csv"; "instruments.csv" ] ~f:(fun file ->
      Sys.file_exists (Filename.concat path file) >>| Poly.equal `Yes)
    >>| fun yes -> if yes then Some path else None
  in
  Sys.ls_dir root
  >>= fun names ->
  Deferred.List.filter_map
    ~how:`Sequential
    (List.sort names ~compare:String.compare)
    ~f:valid
;;
