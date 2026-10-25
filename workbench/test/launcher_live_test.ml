open Core
open Async
open Backtest_viewer

let check message yes = if not yes then failwith message

let run backtest_directory service_directory output_parent =
  let snapshot =
    Filename.concat backtest_directory "data/binance-spot-1d-2023-10_2026-09"
  in
  let start () =
    Launcher.launch
      ~backtest_directory
      ~service_directory
      ~rayforce:"rayforce"
      ~strategy:"trend"
      ~snapshot
      ~output_parent
  in
  let job = start () in
  Ivar.read job.finished
  >>= fun () ->
  (match job.phase with
   | Completed info ->
     check
       "main and baseline"
       (List.equal String.equal info.strategies [ "trend"; "buyhold" ]);
     check "cash scale present" (Option.is_some info.cash_scale);
     printf "Real strategy published: %s\n%!" job.directory
   | _ -> failwith (String.concat ~sep:"\n" (List.rev job.logs)));
  Session.open_bundle
    ~rayforce:"rayforce"
    ~service_directory
    ~directory:job.directory
    ~cancelled:(fun () -> false)
  >>= fun opened ->
  let session = Or_error.ok_exn opened in
  Session.shutdown session
  >>= fun () ->
  let cancelled = start () in
  let rec started () =
    if Option.is_some cancelled.process
    then Deferred.unit
    else if Ivar.is_full cancelled.finished
    then failwith "Run finished before active cancellation test"
    else Clock_ns.after (Time_ns.Span.of_int_ms 1) >>= started
  in
  started ()
  >>= fun () ->
  Launcher.cancel cancelled;
  Ivar.read cancelled.finished
  >>= fun () ->
  check
    "cancelled terminal state"
    (match cancelled.phase with
     | Cancelled -> true
     | _ -> false);
  Sys.file_exists cancelled.directory
  >>= fun exists ->
  check "cancelled run not published" (Poly.equal exists `No);
  printf "Launcher: real strategy, baseline, native reopen and cancellation passed\n%!";
  Deferred.unit
;;

let () =
  let args = Sys.get_argv () in
  don't_wait_for (run args.(1) args.(2) args.(3) >>= fun () -> Shutdown.exit 0);
  never_returns (Scheduler.go ())
;;
