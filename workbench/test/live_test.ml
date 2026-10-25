open Core
open Async
open Backtest_shared
open Model
open Protocol
module Reader = Backtest_reader.Reader
module _ : Providers.Reader = Reader

let scope = { run = "fixture1"; strategy = "fixture" }
let time text = Time_ns.of_string_with_utc_offset text

let range start stop =
  Result.ok_or_failwith (Time_range.make ~start:(time start) ~stop:(time stop))
;;

let page
      ?(table = Equity)
      ?interval
      ?instrument
      ?order_id
      ?(sort = [])
      ?(offset = 0L)
      ?(limit = 100)
      ()
  =
  Rows { scope; table; interval; instrument; order_id; sort; offset; limit }
;;

let next_id = ref 10L

let request operation =
  Int64.incr next_id;
  { id = !next_id; generation = 7L; operation }
;;

let check message condition = if not condition then failwith message

let wait_until f =
  let rec loop () =
    match f () with
    | Some value -> return value
    | None -> Clock_ns.after (Time_ns.Span.of_int_ms 1) >>= loop
  in
  Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) (loop ())
  >>| function
  | `Result value -> value
  | `Timeout -> failwith "reader test timed out"
;;

let response reader =
  wait_until (fun () ->
    match Reader.poll reader ~max_events:1 with
    | [] -> None
    | [ r ] -> Some r
    | _ -> assert false)
;;

let query reader operation =
  let req = request operation in
  (match Reader.submit reader req with
   | Ok () -> ()
   | Error _ -> failwith "submit rejected");
  response reader
  >>| fun result ->
  check "correlation ID" (Int64.equal req.id result.id);
  check "selection generation" (Int64.equal req.generation result.generation);
  result.result
;;

let expect_page = function
  | Ok (Page page) -> page
  | Error
      ( Invalid_output message
      | Invalid_request message
      | Io_error message
      | Unavailable message ) -> failwith ("page failed: " ^ message)
  | Error _ -> failwith "page failed"
  | _ -> failwith "not a page"
;;

let ids page = Array.to_list (Array.map page.rows ~f:(fun row -> row.id.source_row))

let check_ids page expected =
  check "physical row IDs" (List.equal Int64.equal (ids page) expected)
;;

let stalled_peer ~handshake ~cancel =
  let connected = Ivar.create () in
  let handler _address input output =
    let bytes = Bytes.create 2 in
    Async.Reader.really_read input bytes
    >>= fun _ ->
    Ivar.fill_if_empty connected ();
    (if handshake
     then (
       Writer.write output "\003\000";
       Writer.flushed output)
     else Deferred.unit)
    >>= fun () -> Async.Reader.contents input >>| fun _ -> ()
  in
  Tcp.Server.create
    ~on_handler_error:`Raise
    (Tcp.Where_to_listen.bind_to Localhost On_port_chosen_by_os)
    handler
  >>= fun server ->
  let reader =
    Reader.create
      ~timeout:(Time_ns.Span.of_int_ms 50)
      ~host:"127.0.0.1"
      ~port:(Tcp.Server.listening_on server)
      ()
  in
  let req = request (Describe "fixture1") in
  check "submit stalled peer" (Result.is_ok (Reader.submit reader req));
  (if cancel
   then Ivar.read connected >>| fun () -> Reader.cancel reader ~id:req.id
   else Deferred.unit)
  >>= fun () ->
  response reader
  >>= fun result ->
  check
    "stalled peer terminal response"
    (match cancel, result.result with
     | true, Error Cancelled | false, Error (Io_error _) -> true
     | _ -> false);
  Reader.shutdown reader;
  wait_until (fun () -> if Reader.is_closed reader then Some () else None)
  >>= fun () ->
  Tcp.Server.close ~close_existing_connections:true server
  >>= fun () -> Tcp.Server.close_finished_and_handlers_determined server
;;

let urgent_peer ~cancel =
  let ready = Ivar.create () in
  let urgent = Ivar.create () in
  let read_exactly input size =
    let bytes = Bytes.create size in
    Async.Reader.really_read input bytes
    >>| function
    | `Ok -> bytes
    | `Eof _ -> failwith "peer closed before complete request"
  in
  let handler _address input output =
    let socket = Socket.of_fd (Async.Reader.fd input) Socket.Type.tcp in
    Socket.setopt socket Socket.Opt.oobinline true;
    read_exactly input 2
    >>= fun _ ->
    Writer.write output "\003\000";
    Writer.flushed output
    >>= fun () ->
    read_exactly input Rayforce_ipc.Wire.header_len
    >>= fun bytes ->
    let header =
      Rayforce_ipc.Wire.consume_header (Iobuf.of_string (Bytes.to_string bytes))
    in
    read_exactly input header.payload_len
    >>= fun _ ->
    Ivar.fill_exn ready ();
    Async.Reader.read_char input
    >>| fun byte ->
    Ivar.fill_exn
      urgent
      (match byte with
       | `Ok '!' -> true
       | _ -> false)
  in
  Tcp.Server.create
    ~on_handler_error:`Raise
    (Tcp.Where_to_listen.bind_to Localhost On_port_chosen_by_os)
    handler
  >>= fun server ->
  let reader =
    Reader.create
      ~timeout:(Time_ns.Span.of_int_ms 200)
      ~host:"127.0.0.1"
      ~port:(Tcp.Server.listening_on server)
      ()
  in
  let req = request (Describe "fixture1") in
  check "submit urgent test" (Result.is_ok (Reader.submit reader req));
  Ivar.read ready
  >>= fun () ->
  if cancel then Reader.cancel reader ~id:req.id;
  response reader
  >>= fun response ->
  check
    "urgent test result"
    (match cancel, response.result with
     | true, Error Cancelled | false, Error (Io_error _) -> true
     | _ -> false);
  Reader.shutdown reader;
  wait_until (fun () -> if Reader.is_closed reader then Some () else None)
  >>= fun () ->
  Ivar.read urgent
  >>= fun observed ->
  check "Reader sent engine cancellation byte" observed;
  Tcp.Server.close ~close_existing_connections:true server
  >>= fun () -> Tcp.Server.close_finished_and_handlers_determined server
;;

let raw_protocol_tests port =
  Rayforce_ipc_async.Conn.connect ~host:"127.0.0.1" ~port ()
  >>= fun connection ->
  let conn = Or_error.ok_exn connection in
  let exchange value = Rayforce_ipc_async.Conn.send_sync conn value >>| Or_error.ok_exn in
  let req = request (page ()) in
  let replace name value =
    match Backtest_reader.Codec.encode req with
    | Rayforce_ipc.Value.Dict (Syms keys, List values) ->
      let values =
        Array.mapi values ~f:(fun i old ->
          if String.equal (Rayforce_ipc.Sym.to_string keys.(i)) name then value else old)
      in
      Rayforce_ipc.Value.Dict (Syms keys, List values)
    | _ -> assert false
  in
  exchange (Rayforce_ipc.Value.String "(set wb_run \"CORRUPTED\")")
  >>= fun reply ->
  check
    "source text is not evaluated"
    (match reply with
     | Rayforce_ipc.Value.Error _ -> true
     | _ -> false);
  exchange (replace "version" (Rayforce_ipc.Value.Int 99L))
  >>= fun reply ->
  check
    "unsupported API version"
    (match Backtest_reader.Codec.decode req reply with
     | Error (Unsupported_version 99) -> true
     | _ -> false);
  exchange
    (replace
       "table"
       (Rayforce_ipc.Value.Sym (Rayforce_ipc.Sym.intern "equity; (set wb_run bad)")))
  >>= fun reply ->
  check
    "unknown table is data"
    (match Backtest_reader.Codec.decode req reply with
     | Error (Invalid_request _) -> true
     | _ -> false);
  exchange (Backtest_reader.Codec.encode req)
  >>= fun reply ->
  check
    "rejected source did not mutate run"
    (Result.is_ok (Backtest_reader.Codec.decode req reply));
  Rayforce_ipc_async.Conn.close conn
;;

let saved_run = Array.exists (Sys.get_argv ()) ~f:(String.equal "--saved")

let main port =
  let reader = Reader.create ~capacity:2 ~host:"127.0.0.1" ~port () in
  query reader (Describe "fixture1")
  >>= fun result ->
  (match result with
   | Ok (Run_info (info, completion)) ->
     (match saved_run, completion, info.schema_version with
      | false, Legacy_unverified, Legacy_unversioned -> ()
      | true, Validated_complete, Version 1 ->
        check "saved configuration" (Option.is_some info.effective_config);
        let parameters =
          List.Assoc.find_exn
            (Option.value_exn info.strategy_parameters)
            "fixture"
            ~equal:String.equal
        in
        check
          "saved exact integer"
          (match List.Assoc.find_exn parameters "exact" ~equal:String.equal with
           | P_int n -> Int64.equal n 9007199254740993L
           | _ -> false);
        check
          "saved nanosecond span"
          (match List.Assoc.find_exn parameters "span" ~equal:String.equal with
           | P_span span -> Int64.equal (Rayforce_ipc.Timespan.of_span span) 1L
           | _ -> false);
        check
          "saved nanosecond time"
          (match List.Assoc.find_exn parameters "at" ~equal:String.equal with
           | P_timestamp at ->
             Int64.equal (Rayforce_ipc.Timestamp.of_time_ns_int64 at) 820540800000000001L
           | _ -> false)
      | _ -> failwith "unexpected run publication status");
     check "strategies" (List.equal String.equal info.strategies [ "fixture" ])
   | _ -> failwith "metadata");
  query reader (Summary scope)
  >>= fun result ->
  (match result with
   | Ok (Summary_data summary) ->
     check
       "one-hour span"
       (Int64.equal (Rayforce_ipc.Timespan.of_span summary.return_period) 3600000000000L);
     check
       "engine metrics"
       (List.exists summary.metrics ~f:(fun metric -> String.equal metric.key "net_pnl"));
     check
       "last valuation included"
       (Time_range.contains summary.evaluation_window (time "2026-01-01 04:00:00Z"))
   | _ -> failwith "summary");
  Deferred.List.iter
    ~how:`Sequential
    [ Targets; Orders; Order_events; Fills; Ledger; Positions; Equity; Attribution ]
    ~f:(fun table ->
      query reader (page ~table ())
      >>| fun result -> ignore (expect_page result : Protocol.page))
  >>= fun () ->
  query reader (page ~sort:[ "equity", Ascending ] ())
  >>= fun result ->
  check_ids (expect_page result) [ 3L; 4L; 2L; 0L; 1L ];
  query
    reader
    (page ~sort:[ "fees", Descending; "equity", Ascending ] ~offset:1L ~limit:3 ())
  >>= fun result ->
  check_ids (expect_page result) [ 3L; 2L; 0L ];
  query reader (page ~offset:Int64.max_value ())
  >>= fun result ->
  let p = expect_page result in
  check_ids p [];
  check "filtered total" (Option.equal Int64.equal p.total_rows (Some 5L));
  query
    reader
    (page
       ~table:Positions
       ~instrument:"A"
       ~interval:(range "2026-01-01 01:00:00Z" "2026-01-01 03:00:00Z")
       ~sort:[ "qty", Descending ]
       ())
  >>= fun result ->
  check_ids (expect_page result) [ 4L; 2L ];
  query reader (page ~table:Positions ~limit:2 ())
  >>= fun result ->
  let p = expect_page result in
  check
    "nullable mark"
    (match p.rows.(0).cells.(4), p.rows.(0).cells.(5) with
     | Null, Null -> true
     | _ -> false);
  query reader (page ~table:Fills ~order_id:2L ())
  >>= fun result ->
  check_ids (expect_page result) [ 1L ];
  let q =
    { scope
    ; table = Equity
    ; field = "equity"
    ; interval = range "2026-01-01 00:00:00Z" "2026-01-01 05:00:00Z"
    ; instrument = None
    ; pixel_width = 1
    ; max_points = 4
    }
  in
  query reader (Series q)
  >>= fun result ->
  (match result with
   | Ok (Series_data s) ->
     check "sample count" (Array.length s.points <= 4);
     check
       "minimum retained"
       (Array.exists s.points ~f:(fun point ->
          Option.equal Int64.equal point.value (Some 96866L)));
     check
       "maximum retained"
       (Array.exists s.points ~f:(fun point ->
          Option.equal Int64.equal point.value (Some 100000L)));
     check
       "sampling metadata"
       (match s.sampling with
        | Extrema_envelope { source_points; buckets = 1 } -> Int64.equal source_points 5L
        | _ -> false)
   | _ -> failwith "sampled series");
  query reader (Series { q with max_points = 10 })
  >>= fun result ->
  (match result with
   | Ok (Series_data { sampling = Exact; points; _ }) ->
     check "exact count" (Array.length points = 5)
   | _ -> failwith "exact series");
  query
    reader
    (Series
       { q with table = Positions; field = "mark"; instrument = Some "A"; max_points = 2 })
  >>= fun result ->
  check
    "insufficient gap budget"
    (match result with
     | Error (Unavailable _) -> true
     | _ -> false);
  query
    reader
    (Series
       { q with table = Positions; field = "mark"; instrument = Some "A"; max_points = 4 })
  >>= fun result ->
  (match result with
   | Ok (Series_data s) -> check "gap retained" (Option.is_none s.points.(0).value)
   | _ -> failwith "gap series");
  query
    reader
    (Series { q with interval = range "2027-01-01 00:00:00Z" "2027-01-02 00:00:00Z" })
  >>= fun result ->
  (match result with
   | Ok (Series_data s) -> check "empty series" (Array.is_empty s.points)
   | _ -> failwith "empty series");
  let one = request (Describe "fixture1")
  and two = request (page ())
  and three = request (page ()) in
  check "submit first" (Result.is_ok (Reader.submit reader one));
  check "submit queued" (Result.is_ok (Reader.submit reader two));
  check
    "bounded capacity"
    (match Reader.submit reader three with
     | Error Busy -> true
     | _ -> false);
  Reader.cancel reader ~id:two.id;
  response reader
  >>= fun _ ->
  response reader
  >>= fun result ->
  check
    "queued cancellation"
    (match result.result with
     | Error Cancelled -> true
     | _ -> false);
  check
    "duplicate ID"
    (match Reader.submit reader one with
     | Error (Invalid_request _) -> true
     | _ -> false);
  query reader (Describe "missing")
  >>= fun result ->
  check
    "unknown run"
    (match result with
     | Error (Unavailable _) -> true
     | _ -> false);
  Reader.shutdown reader;
  wait_until (fun () -> if Reader.is_closed reader then Some () else None)
  >>| fun () ->
  check "closed submission" (Result.is_error (Reader.submit reader (request (page ()))));
  ()
;;

let all port =
  main port
  >>= fun () ->
  raw_protocol_tests port
  >>= fun () ->
  urgent_peer ~cancel:true
  >>= fun () ->
  urgent_peer ~cancel:false
  >>= fun () ->
  stalled_peer ~handshake:true ~cancel:false
  >>= fun () ->
  stalled_peer ~handshake:true ~cancel:true
  >>= fun () ->
  stalled_peer ~handshake:false ~cancel:true
  >>| fun () -> printf "PASS workbench IPC live tests\n"
;;

let () =
  don't_wait_for
    (Monitor.try_with (fun () -> all (Int.of_string (Sys.get_argv ()).(1)))
     >>= function
     | Ok () -> Shutdown.exit 0
     | Error exn ->
       eprintf "%s\n" (Exn.to_string exn);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
;;
