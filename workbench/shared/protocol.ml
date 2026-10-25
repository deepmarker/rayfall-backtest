open Core
open Model

type error =
  | Invalid_request of string
  | Unsupported_version of int
  | Unavailable of string
  | Invalid_output of string
  | Busy
  | Cancelled
  | Io_error of string

type direction =
  | Ascending
  | Descending

type row_query =
  { scope : scope
  ; table : table
  ; interval : Time_range.t option
  ; instrument : string option
  ; order_id : int64 option
  ; sort : (string * direction) list
  ; offset : int64
  ; limit : int
  }

type series_query =
  { scope : scope
  ; table : table
  ; field : string
  ; interval : Time_range.t
  ; instrument : string option
  ; pixel_width : int
  ; max_points : int
  }

type operation =
  | Describe of run_id
  | Summary of scope
  | Rows of row_query
  | Series of series_query

(** IDs are unique for the provider lifetime. Generation belongs to the UI
    selection: it changes whenever selection changes, independently of ID. *)
type request =
  { id : int64
  ; generation : int64
  ; operation : operation
  }

type row =
  { id : record_id
  ; cells : cell array
  }

(** Total is after filtering, not the whole source file; absent if not computed. *)
type page =
  { scope : scope
  ; table : table
  ; fields : field array
  ; rows : row array
  ; offset : int64
  ; total_rows : int64 option
  }

type point =
  { record : record_id
  ; at : Time_ns.t
  ; value : int64 option
  }

type sampling =
  | Exact
  | Extrema_envelope of
      { source_points : int64
      ; buckets : int
      }

(** Points preserve source timestamps/IDs and ordering, including null gaps.
    An envelope retains extrema, not averages or synthetic financial values. *)
type series =
  { scope : scope
  ; field : field
  ; interval : Time_range.t
  ; points : point array
  ; sampling : sampling
  }

type reply =
  | Run_info of run_info * completion
  | Summary_data of summary
  | Page of page
  | Series_data of series

type response =
  { id : int64
  ; generation : int64
  ; result : (reply, error) result
  }

let max_page_rows = 10000
let max_pixel_width = 16384
let invalid message = Error (Invalid_request message)
let valid_symbol s = (not (String.is_empty s)) && not (String.contains s '\000')
let valid_scope scope = (not (String.is_empty scope.run)) && valid_symbol scope.strategy

let validate_rows (q : row_query) =
  if not (valid_scope q.scope)
  then invalid "run and strategy are required"
  else if not (Option.for_all q.instrument ~f:valid_symbol)
  then invalid "invalid instrument symbol"
  else if Int64.compare q.offset 0L < 0
  then invalid "negative offset"
  else if q.limit < 1 || q.limit > max_page_rows
  then invalid "page limit must be 1..10000"
  else (
    let fields = current_schema q.table in
    let has name = Array.exists fields ~f:(fun f -> String.equal f.name name) in
    if Option.is_some q.instrument && not (has "sym")
    then invalid "table has no instrument field"
    else if Option.is_some q.order_id && not (has "order_id")
    then invalid "table has no order_id"
    else if List.exists q.sort ~f:(fun (name, _) -> not (has name))
    then invalid "unknown sort field"
    else Ok ())
;;

let validate_series (q : series_query) =
  if not (valid_scope q.scope)
  then invalid "run and strategy are required"
  else if not (Option.for_all q.instrument ~f:valid_symbol)
  then invalid "invalid instrument symbol"
  else if q.pixel_width < 1 || q.pixel_width > max_pixel_width
  then invalid "pixel width must be 1..16384"
  else if q.max_points < 1 || q.max_points > 65536
  then invalid "series point budget must be 1..65536"
  else (
    let fields = current_schema q.table in
    let numeric f =
      String.equal f.name q.field
      &&
      match f.kind with
      | Integer _ -> true
      | _ -> false
    in
    let has_time = Array.exists fields ~f:(fun f -> String.equal f.name "ts") in
    let has_symbol = Array.exists fields ~f:(fun f -> String.equal f.name "sym") in
    if not has_time
    then invalid "table has no timestamp"
    else if Option.is_some q.instrument && not has_symbol
    then invalid "table has no instrument field"
    else if has_symbol && Option.is_none q.instrument
    then invalid "instrument required for a single series"
    else if not (Array.exists fields ~f:numeric)
    then invalid "unknown or non-integer series field"
    else Ok ())
;;

let validate = function
  | Describe "" -> invalid "run is required"
  | Describe _ -> Ok ()
  | Summary scope ->
    if valid_scope scope then Ok () else invalid "run and strategy are required"
  | Rows q -> validate_rows q
  | Series q -> validate_series q
;;

let is_current ~generation (response : response) =
  Int64.equal generation response.generation
;;
