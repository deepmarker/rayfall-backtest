open Core
open Async
open Backtest_shared
module Bundle = Backtest_bundle.Bundle
module V = Rayforce_ipc.Value
module Sym = Rayforce_ipc.Sym

(* Filesystem publication tests deliberately stub native validation. Real engine
   export is separately blocked by Rayforce #987; these do not claim to test it. *)
let dict fields =
  V.Dict
    ( V.Syms (Array.of_list_map fields ~f:(fun (name, _) -> Sym.intern name))
    , V.List (Array.of_list_map fields ~f:snd) )
;;

let i n = V.Int n
let s text = V.String text

let metadata ?(version = 1L) run =
  let config =
    dict
      [ "cash0", i 100L
      ; "fee_ppm", i 0L
      ; "start", V.Timestamp 0L
      ; "period", V.Timespan 1L
      ; "steps", i 1L
      ; "max_weight_ppm", i 1000000L
      ; "max_gross_ppm", i 1000000L
      ; "buy_policy", V.Sym (Sym.intern "SCALE")
      ]
  in
  let provenance =
    dict
      [ "framework_revision", s "test"
      ; "snapshot_sha256", s "test"
      ; "rayforce_binary_sha256", s "test"
      ; "rayforce_version", s "test"
      ; "config_text", s "test"
      ; "parameter_text", dict [ "s", s "test" ]
      ]
  in
  let details =
    dict
      [ "version", i 1L
      ; "effective_config", config
      ; ( "parameters"
        , dict
            [ ( "s"
              , dict
                  [ "exact", i 9007199254740993L
                  ; "duration", V.Timespan 1L
                  ; "at", V.Timestamp 1L
                  ] )
            ] )
      ; "snapshot", dict [ "directory", s "test"; "sha256sums_sha256", s "test" ]
      ; "cash_scale", V.Null
      ; "instruments", V.Null
      ]
  in
  let summary =
    dict
      [ "start", V.Timestamp 0L
      ; "stop", V.Timestamp 1L
      ; "warmup", i 0L
      ; "period", V.Timespan 1L
      ; "periods_per_year", V.Float 365.
      ; "risk_free_rate", V.Float 0.
      ; "metrics", dict [ "trades", i 0L ]
      ; "assumptions", V.List [||]
      ]
  in
  dict
    [ "version", i version
    ; "run", s run
    ; "metadata", provenance
    ; "strategies", V.Syms [| Sym.intern "s" |]
    ; "summaries", dict [ "s", summary ]
    ; "details", details
    ; "rows", V.List [| V.Ints (Array.create ~len:8 0L) |]
    ]
;;

let write_metadata ?version directory run =
  let value = metadata ?version run in
  let bytes = Iobuf.create ~len:(Rayforce_ipc.Wire.frame_size value) in
  Rayforce_ipc.Wire.fill_frame bytes ~msgtype:Async value;
  Iobuf.flip_lo bytes;
  Writer.save (Filename.concat directory "metadata.rfn") ~contents:(Iobuf.to_string bytes)
;;

let write ?version run ~directory =
  Monitor.try_with_or_error (fun () ->
    write_metadata ?version directory run
    >>= fun () -> Writer.save (Filename.concat directory "artifact.bin") ~contents:run)
;;

let check message condition = if not condition then failwith message

let publish directory write =
  Bundle.publish
    ~directory
    ~rayforce:"/bin/true"
    ~service_directory:"unused-in-unit-test"
    ~write
;;

let absent path =
  Sys.file_exists path
  >>| fun exists -> check "destination absent" (Poly.equal exists `No)
;;

let test directory =
  let path name = Filename.concat directory name in
  publish (path "saved") (write "saved")
  >>= fun published ->
  let info = Or_error.ok_exn published in
  check
    "version"
    (match info.schema_version with
     | Model.Version 1 -> true
     | _ -> false);
  let params =
    List.Assoc.find_exn
      (Option.value_exn info.strategy_parameters)
      "s"
      ~equal:String.equal
  in
  check
    "exact integer metadata"
    (match List.Assoc.find_exn params "exact" ~equal:String.equal with
     | P_int n -> Int64.equal n 9007199254740993L
     | _ -> false);
  Bundle.verify ~directory:(path "saved")
  >>= fun verified ->
  check "reopen identity" (String.equal (Or_error.ok_exn verified).id "saved");
  publish (path "saved") (write "replacement")
  >>= fun replaced ->
  check "existing destination refused" (Result.is_error replaced);
  let interrupted ~directory =
    Writer.save (Filename.concat directory "partial") ~contents:"partial"
    >>| fun () -> Or_error.error_string "interrupted"
  in
  publish (path "interrupted") interrupted
  >>= fun failed ->
  check "interruption failed" (Result.is_error failed);
  absent (path "interrupted")
  >>= fun () ->
  let cancelled = ref false in
  let cancel_before_commit ~directory =
    write "cancelled" ~directory
    >>| fun wrote ->
    cancelled := true;
    wrote
  in
  Bundle.publish_cancellable
    ~cancelled:(fun () -> !cancelled)
    ~directory:(path "cancelled")
    ~rayforce:"/bin/true"
    ~service_directory:directory
    ~write:cancel_before_commit
  >>= fun result ->
  check "publication observes cancellation" (Result.is_error result);
  absent (path "cancelled")
  >>= fun () ->
  publish (path "unknown") (write ~version:99L "unknown")
  >>= fun failed ->
  check "unsupported version refused" (Result.is_error failed);
  absent (path "unknown")
  >>= fun () ->
  let competing ~directory:staging =
    Unix.mkdir (path "occupied") >>= fun () -> write "ours" ~directory:staging
  in
  publish (path "occupied") competing
  >>= fun failed ->
  check "rename does not replace raced empty directory" (Result.is_error failed);
  Sys.ls_dir (path "occupied")
  >>= fun contents ->
  check "raced destination unchanged" (List.is_empty contents);
  let started = ref 0 in
  let gate = Ivar.create () in
  let racing run ~directory =
    incr started;
    if !started = 2 then Ivar.fill_exn gate ();
    Ivar.read gate >>= fun () -> write run ~directory
  in
  Deferred.both
    (publish (path "race") (racing "one"))
    (publish (path "race") (racing "two"))
  >>= fun (one, two) ->
  check "one concurrent publisher wins" Bool.(Result.is_ok one <> Result.is_ok two);
  Bundle.verify ~directory:(path "race")
  >>= fun winner ->
  let winner = (Or_error.ok_exn winner).id in
  check "winner intact" (List.mem [ "one"; "two" ] winner ~equal:String.equal);
  Writer.save (Filename.concat (path "saved") "artifact.bin") ~contents:"corrupt"
  >>= fun () ->
  Bundle.verify ~directory:(path "saved")
  >>= fun corrupt ->
  check "corruption detected" (Result.is_error corrupt);
  Writer.save (Filename.concat (path "race") "COMPLETED") ~contents:"partial"
  >>= fun () ->
  Bundle.verify ~directory:(path "race")
  >>= fun incomplete ->
  check "incomplete seal refused" (Result.is_error incomplete);
  Sys.ls_dir directory
  >>| fun names ->
  check
    "staging cleaned on controlled failures"
    (not (List.exists names ~f:(String.is_prefix ~prefix:".workbench-staging")))
;;

let () =
  don't_wait_for
    (Monitor.try_with (fun () ->
       Unix.mkdtemp "/tmp/workbench-bundle-test-"
       >>= fun directory ->
       Monitor.protect
         (fun () -> test directory)
         ~finally:(fun () ->
           Process.run ~prog:"rm" ~args:[ "-rf"; "--"; directory ] () >>| fun _ -> ()))
     >>= function
     | Ok () ->
       printf "PASS bundle filesystem tests (native validator stubbed)\n";
       Shutdown.exit 0
     | Error exn ->
       eprintf "%s\n" (Exn.to_string exn);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
;;
