open Core
open Backtest_shared
open Model
open Protocol
module Reader = Backtest_reader.Reader

type slot = { mutable id : int64 option }

type t =
  { session : Session.t
  ; mutable strategy : string
  ; mutable summary : summary option
  ; mutable exact_series : series option
  ; mutable series : series option
  ; mutable page_cursor : Time_ns.t option
  ; mutable requested_page_cursor : Time_ns.t option
  ; mutable page : page option
  ; mutable display_rows : string array array
  ; mutable full_range : Time_range.t option
  ; mutable range : Time_range.t option
  ; mutable cursor : Time_ns.t option
  ; mutable table : table
  ; mutable offset : int64
  ; mutable focus : bool
  ; mutable error : string option
  ; summary_slot : slot
  ; series_slot : slot
  ; page_slot : slot
  ; mutable next_id : int64
  ; mutable series_due : Time_ns.t option
  ; mutable page_due : Time_ns.t option
  }

let error_text = function
  | Invalid_request s | Unavailable s | Invalid_output s | Io_error s -> s
  | Unsupported_version n -> sprintf "Unsupported version %d" n
  | Busy -> "Reader queue is full"
  | Cancelled -> "Cancelled"
;;

let cell_text = function
  | Null -> "null"
  | Int64 n -> Int64.to_string n
  | Time t -> Time_ns.to_string_utc t
  | Sym s | Str s -> s
  | F64 n -> Float.to_string n
;;

let scope t = { run = t.session.info.id; strategy = t.strategy }

let invalidate t slot =
  Option.iter slot.id ~f:(fun id -> Reader.cancel t.session.reader ~id);
  slot.id <- None
;;

let submit t slot operation =
  invalidate t slot;
  t.next_id <- Int64.succ t.next_id;
  let request = { id = t.next_id; generation = 0L; operation } in
  match Reader.submit t.session.reader request with
  | Ok () -> slot.id <- Some request.id
  | Error e -> t.error <- Some (error_text e)
;;

let due () = Some (Time_ns.add (Time_ns.now ()) (Time_ns.Span.of_int_ms 25))

let set_cursor t at =
  let changed = not (Option.equal Time_ns.equal t.cursor (Some at)) in
  t.cursor <- Some at;
  if t.focus && (changed || not (Int64.equal t.offset 0L))
  then (
    t.offset <- 0L;
    invalidate t t.page_slot;
    t.page_due <- due ())
;;

let same_range a b =
  Time_ns.equal a.Time_range.start_inclusive b.Time_range.start_inclusive
  && Time_ns.equal a.end_exclusive b.end_exclusive
;;

let set_range t range =
  if not (Option.exists t.range ~f:(same_range range))
  then (
    t.range <- Some range;
    invalidate t t.series_slot;
    match t.exact_series with
    | Some cached
      when Time_ns.(
             cached.interval.start_inclusive <= range.start_inclusive
             && cached.interval.end_exclusive >= range.end_exclusive) ->
      let points =
        Array.filter cached.points ~f:(fun point -> Time_range.contains range point.at)
      in
      t.series <- Some { cached with interval = range; points };
      t.series_due <- None
    | _ -> t.series_due <- due ())
;;

let rows_changed t =
  invalidate t t.page_slot;
  t.page_due <- due ()
;;

let select_strategy t strategy =
  t.strategy <- strategy;
  t.error <- None;
  invalidate t t.series_slot;
  invalidate t t.page_slot;
  t.summary <- None;
  t.series <- None;
  t.exact_series <- None;
  t.page <- None;
  t.display_rows <- [||];
  t.range <- None;
  t.full_range <- None;
  t.cursor <- None;
  t.offset <- 0L;
  t.series_due <- None;
  t.page_due <- None;
  submit t t.summary_slot (Summary (scope t))
;;

let create session =
  let t =
    { session
    ; strategy = ""
    ; summary = None
    ; exact_series = None
    ; series = None
    ; page_cursor = None
    ; requested_page_cursor = None
    ; page = None
    ; display_rows = [||]
    ; full_range = None
    ; range = None
    ; cursor = None
    ; table = Positions
    ; offset = 0L
    ; focus = true
    ; error = None
    ; summary_slot = { id = None }
    ; series_slot = { id = None }
    ; page_slot = { id = None }
    ; next_id = 0L
    ; series_due = None
    ; page_due = None
    }
  in
  select_strategy t (List.hd_exn session.info.strategies);
  t
;;

let page_interval t =
  match t.focus, t.cursor, t.full_range, t.summary with
  | true, Some start, Some full, Some summary ->
    let remaining = Int64.(Chart.ns full.end_exclusive - Chart.ns start) in
    let period = Int63.to_int64 (Time_ns.Span.to_int63_ns summary.return_period) in
    let width = Int64.min remaining (Int64.max 1L period) in
    let stop =
      Time_ns.of_int63_ns_since_epoch (Int63.of_int64_exn Int64.(Chart.ns start + width))
    in
    Result.ok (Time_range.make ~start ~stop)
  | _ -> None
;;

let fetch_rows t =
  t.requested_page_cursor <- (if t.focus then t.cursor else None);
  submit
    t
    t.page_slot
    (Rows
       { scope = scope t
       ; table = t.table
       ; interval = page_interval t
       ; instrument = None
       ; order_id = None
       ; sort = []
       ; offset = t.offset
       ; limit = 1000
       })
;;

let fetch_series t =
  Option.iter t.range ~f:(fun interval ->
    submit
      t
      t.series_slot
      (Series
         { scope = scope t
         ; table = Equity
         ; field = "equity"
         ; interval
         ; instrument = None
         ; pixel_width = 1000
         ; max_points = 4000
         }))
;;

let accept t (response : response) =
  let slot =
    List.find [ t.summary_slot; t.series_slot; t.page_slot ] ~f:(fun s ->
      Option.equal Int64.equal s.id (Some response.id))
  in
  match slot with
  | None -> ()
  | Some slot ->
    slot.id <- None;
    (match response.result with
     | Error Cancelled -> ()
     | Error e -> t.error <- Some (error_text e)
     | Ok (Summary_data summary) ->
       t.summary <- Some summary;
       let start =
         match t.session.info.effective_config with
         | Some config -> config.start
         | None -> summary.evaluation_window.start_inclusive
       in
       let full =
         Result.ok_or_failwith
           (Time_range.make ~start ~stop:summary.evaluation_window.end_exclusive)
       in
       t.full_range <- Some full;
       t.range <- Some full;
       t.cursor <- Some start;
       fetch_series t;
       fetch_rows t
     | Ok (Series_data series) ->
       t.series <- Some series;
       (match series.sampling, t.exact_series with
        | Exact, None -> t.exact_series <- Some series
        | Exact, Some cached
          when Time_ns.(
                 series.interval.start_inclusive <= cached.interval.start_inclusive
                 && series.interval.end_exclusive >= cached.interval.end_exclusive) ->
          t.exact_series <- Some series
        | _ -> ())
     | Ok (Page page) ->
       t.page_cursor <- t.requested_page_cursor;
       t.page <- Some page;
       t.display_rows
       <- Array.map page.rows ~f:(fun row -> Array.map row.cells ~f:cell_text)
     | Ok (Run_info _) -> ())
;;

let tick t =
  if Async.Deferred.is_determined t.session.exited && Option.is_none t.session.stopping
  then
    t.error
    <- Some ("Result service exited: " ^ String.concat ~sep:"\n" (List.rev t.session.logs));
  List.iter (Reader.poll t.session.reader ~max_events:16) ~f:(accept t);
  let instant = Time_ns.now () in
  if Option.exists t.series_due ~f:(fun due -> Time_ns.(due <= instant))
  then (
    t.series_due <- None;
    fetch_series t);
  if Option.exists t.page_due ~f:(fun due -> Time_ns.(due <= instant))
  then (
    t.page_due <- None;
    fetch_rows t)
;;
