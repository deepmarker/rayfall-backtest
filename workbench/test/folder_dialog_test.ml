open Core
open Async
open Backtest_viewer

let check message condition = if not condition then failwith message

let test root =
  let prog = Filename.concat root "chooser" in
  let directory = Filename.concat root "a directory " in
  Unix.mkdir directory
  >>= fun () ->
  let invoke script =
    Writer.save prog ~contents:("#!/bin/sh\n" ^ script)
    >>= fun () ->
    Unix.chmod prog ~perm:0o700
    >>= fun () ->
    let child = ref None in
    Folder_dialog.choose
      ~prog
      ~initial_directory:root
      ~on_process:(fun p -> child := Some p)
      ()
    >>| fun result ->
    check
      "chooser reaped"
      (Deferred.is_determined (Process.wait (Option.value_exn !child)));
    result
  in
  invoke "printf '%s\\n' \"${0%/*}/a directory \"\n"
  >>= fun picked ->
  check
    "spaces preserved"
    (Option.equal String.equal (Or_error.ok_exn picked) (Some directory));
  invoke "exit 1\n"
  >>= fun cancelled ->
  check "cancel is not an error" (Option.is_none (Or_error.ok_exn cancelled));
  invoke "printf '%s\\n' \"$0\"\n"
  >>= fun file ->
  check "file rejected" (Result.is_error file);
  invoke "echo failure >&2; exit 2\n"
  >>| fun failed -> check "chooser failure reported" (Result.is_error failed)
;;

let () =
  let run () =
    Unix.mkdtemp "/tmp/workbench-dialog-"
    >>= fun root ->
    Monitor.protect
      (fun () -> test root)
      ~finally:(fun () ->
        Process.run ~prog:"rm" ~args:[ "-rf"; "--"; root ] () >>| fun _ -> ())
  in
  don't_wait_for
    (Monitor.try_with_or_error run
     >>= function
     | Ok () -> Shutdown.exit 0
     | Error error ->
       eprintf "%s\n" (Error.to_string_hum error);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
;;
