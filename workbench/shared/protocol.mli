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

(** Cheap request-shape validation. Does not execute Rayfall or validate trading
    rules. Providers also check run availability, metadata and schemas. *)
val validate : operation -> (unit, error) result

val is_current : generation:int64 -> response -> bool
