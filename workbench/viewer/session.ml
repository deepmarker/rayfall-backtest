open Core
open Async
open Backtest_shared
module Reader = Backtest_reader.Reader
module Conn = Rayforce_ipc_async.Conn

type t =
  { info : Model.run_info
  ; reader : Reader.t
  ; process : Process.t
  ; exited : Unix.Exit_or_signal.t Deferred.t
  ; mutable logs : string list
  ; mutable stopping : unit Deferred.t option
  }

let log t line = t.logs <- List.take (line :: t.logs) 40

let drain t input =
  let line text =
    log t (String.prefix text 1024);
    Deferred.unit
  in
  Pipe.iter (Async.Reader.lines input) ~f:line
;;

let wait_for_exit t =
  Clock_ns.with_timeout (Time_ns.Span.of_int_sec 2) t.exited
  >>= function
  | `Result _ -> Deferred.unit
  | `Timeout ->
    ignore (Process.send_signal_compat t.process Signal.kill : [ `Ok | `No_such_process ]);
    t.exited >>| fun _ -> ()
;;

let shutdown t =
  match t.stopping with
  | Some stopped -> stopped
  | None ->
    Reader.shutdown t.reader;
    ignore (Process.send_signal_compat t.process Signal.term : [ `Ok | `No_such_process ]);
    let rec drain_reader () =
      ignore (Reader.poll t.reader ~max_events:32 : Protocol.response list);
      if Reader.is_closed t.reader
      then Deferred.unit
      else Clock_ns.after (Time_ns.Span.of_int_ms 10) >>= drain_reader
    in
    let stopped = Deferred.all_unit [ wait_for_exit t; drain_reader () ] in
    t.stopping <- Some stopped;
    stopped
;;

let free_port () =
  let on_client _ reader writer =
    Writer.close writer >>= fun () -> Async.Reader.close reader
  in
  Tcp.Server.create
    ~on_handler_error:`Ignore
    (Tcp.Where_to_listen.bind_to Localhost On_port_chosen_by_os)
    on_client
  >>= fun server ->
  let port = Tcp.Server.listening_on server in
  Tcp.Server.close server >>| fun () -> port
;;

let open_verified_bundle ~rayforce ~service_directory ~directory ~cancelled =
  Monitor.try_with_or_error (fun () ->
    Backtest_bundle.Bundle.verify ~directory
    >>= fun verified ->
    let info = Or_error.ok_exn verified in
    if cancelled () then failwith "Opening cancelled";
    free_port ()
    >>= fun port ->
    if cancelled () then failwith "Opening cancelled";
    let args =
      [ "-p"; sprintf "127.0.0.1:%d" port ]
      @ Backtest_bundle.Bundle.native_args ~service_directory ~directory ~staged:false
    in
    Process.create ~prog:rayforce ~args ()
    >>= fun created ->
    let process = Or_error.ok_exn created in
    let t =
      { info
      ; reader = Reader.create ~host:"127.0.0.1" ~port ()
      ; process
      ; exited = Process.wait process
      ; logs = []
      ; stopping = None
      }
    in
    don't_wait_for (Writer.close (Process.stdin process));
    don't_wait_for (drain t (Process.stdout process));
    don't_wait_for (drain t (Process.stderr process));
    let ready () =
      let rec connect attempts =
        if cancelled () then failwith "Opening cancelled";
        if Deferred.is_determined t.exited
        then
          failwith ("Result service exited: " ^ String.concat ~sep:"\n" (List.rev t.logs));
        Conn.connect ~timeout:(Time_ns.Span.of_int_ms 200) ~host:"127.0.0.1" ~port ()
        >>= function
        | Ok conn -> Conn.close conn
        | Error _ when attempts > 0 ->
          Clock_ns.after (Time_ns.Span.of_int_ms 50) >>= fun () -> connect (attempts - 1)
        | Error error -> Error.raise error
      in
      connect 40
    in
    Monitor.try_with_or_error ready
    >>= function
    | Ok () when not (cancelled ()) -> return t
    | result ->
      shutdown t
      >>= fun () ->
      (match result with
       | Ok () -> failwith "Opening cancelled"
       | Error error -> Error.raise error))
;;

let open_bundle ~rayforce ~service_directory ~directory ~cancelled =
  if String.is_empty (String.strip directory)
  then return (Or_error.error_string "Choose a saved-run directory first.")
  else
    Sys.file_exists (Filename.concat directory "COMPLETED")
    >>= function
    | `Yes -> open_verified_bundle ~rayforce ~service_directory ~directory ~cancelled
    | _ ->
      return
        (Or_error.error_string
           "This directory is not a completed saved run. Choose a saved-run folder, or \
            launch a strategy below.")
;;
