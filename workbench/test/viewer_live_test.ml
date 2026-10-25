open Core
open Async
open Backtest_shared
open Backtest_viewer
module C = Controller

let check message condition = if not condition then failwith message

let wait_until f =
  let rec loop () =
    if f () then Deferred.unit else Clock_ns.after (Time_ns.Span.of_int_ms 5) >>= loop
  in
  Clock_ns.with_timeout (Time_ns.Span.of_int_sec 10) (loop ())
  >>| function
  | `Result () -> ()
  | `Timeout -> failwith "viewer timed out"
;;

let run directory service_directory =
  Session.open_bundle
    ~rayforce:"must-not-start"
    ~service_directory
    ~directory:"   "
    ~cancelled:(fun () -> false)
  >>= fun empty ->
  check "blank open rejected without starting a service" (Result.is_error empty);
  Session.open_bundle
    ~rayforce:"rayforce"
    ~service_directory
    ~directory
    ~cancelled:(fun () -> false)
  >>= fun opened ->
  let session = Or_error.ok_exn opened in
  let c = C.create session in
  let ready () =
    C.tick c;
    Option.is_some c.summary
    && Option.is_some c.series
    && Option.is_some c.page
    && Option.is_none c.series_due
    && Option.is_none c.series_slot.id
    && Option.is_none c.page_due
    && Option.is_none c.page_slot.id
  in
  let body () =
    wait_until ready
    >>= fun () ->
    let series = Option.value_exn c.series in
    check "fixture equity points" (Array.length series.points > 2);
    let displayed_page = c.page in
    C.set_cursor c series.points.(1).at;
    check "rows stay visible during refresh" (phys_equal c.page displayed_page);
    wait_until ready
    >>= fun () ->
    let page = Option.value_exn c.page in
    check "cursor filters positions" (Array.length page.rows = 2);
    let timestamp =
      Array.findi page.fields ~f:(fun _ f -> String.equal f.name "ts")
      |> Option.value_exn
      |> fst
    in
    Array.iter page.rows ~f:(fun row ->
      match row.cells.(timestamp) with
      | Model.Time at ->
        check "row timestamp follows cursor" (Time_ns.equal at series.points.(1).at)
      | _ -> failwith "missing timestamp");
    let old_page = c.page in
    C.accept
      c
      { Protocol.id = -1L
      ; generation = 0L
      ; result = Ok (Protocol.Page { page with rows = [||] })
      };
    check "stale response discarded" (phys_equal c.page old_page);
    let full_range = Option.value_exn c.full_range in
    let zoomed =
      Chart.zoom full_range ~full_range ~anchor:0.5 ~factor:0.5 |> Result.ok_or_failwith
    in
    let before_zoom = c.next_id in
    C.set_range c zoomed;
    check
      "exact-series zoom needs no IPC"
      (Int64.equal c.next_id before_zoom && Option.is_none c.series_due);
    check
      "local zoom preserves exact source values"
      (Array.for_all (Option.value_exn c.series).points ~f:(fun point ->
         Array.exists series.points ~f:(fun source -> phys_equal source point)));
    C.set_range c zoomed;
    check "unchanged range does not refresh" (Option.is_none c.series_due);
    wait_until ready
    >>= fun () ->
    check
      "series uses zoomed interval"
      (Time_ns.equal
         (Option.value_exn c.series).interval.start_inclusive
         zoomed.start_inclusive);
    let displayed_series = c.series in
    c.exact_series <- None;
    C.set_range c full_range;
    check "chart stays visible during IPC refresh" (phys_equal c.series displayed_series);
    wait_until ready
    >>= fun () ->
    check
      "server refresh completes"
      (C.same_range (Option.value_exn c.series).interval full_range);
    C.select_strategy c c.strategy;
    wait_until ready
    >>= fun () ->
    printf
      "Viewer integration: cursor, zoom, stale response and strategy refresh passed\n%!";
    Deferred.unit
  in
  Monitor.protect body ~finally:(fun () -> Session.shutdown session)
  >>= fun () ->
  check "owned service reaped" (Deferred.is_determined session.exited);
  check "reader closed" (Backtest_reader.Reader.is_closed session.reader);
  Deferred.unit
;;

let () =
  let args = Sys.get_argv () in
  don't_wait_for (run args.(1) args.(2) >>= fun () -> Shutdown.exit 0);
  never_returns (Scheduler.go ())
;;
