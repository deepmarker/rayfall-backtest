open Core

(** Domain values shared by storage, runner and UI. No renderer or transport. *)
module Time_range : sig
  type t = private
    { start_inclusive : Time_ns.t
    ; end_exclusive : Time_ns.t
    }

  val make : start:Time_ns.t -> stop:Time_ns.t -> (t, string) result
  val contains : t -> Time_ns.t -> bool
end

type run_id = string
type strategy_id = string

(** Order IDs and seq counters are local to this scope, never global IDs. *)
type scope =
  { run : run_id
  ; strategy : strategy_id
  }

type table =
  | Targets
  | Orders
  | Order_events
  | Fills
  | Ledger
  | Positions
  | Equity
  | Attribution

(** Zero-based source data row, excluding CSV headers. Stable across filtering,
    sorting and paging of one immutable completed run. *)
type record_id =
  { scope : scope
  ; table : table
  ; source_row : int64
  }

type selection =
  { scope : scope
  ; interval : Time_range.t option
  ; cursor : Time_ns.t option
  ; instrument : string option
  ; order_id : int64 option
  ; record : record_id option
  }

type integer_unit =
  | Cash_units
  | Lots
  | Price_ticks
  | Multiplier
  | Ppm
  | Counter

type field_kind =
  | Integer of integer_unit
  | Timestamp_ns
  | Symbol
  | Text
  | Float

type field =
  { name : string
  ; kind : field_kind
  ; nullable : bool
  }

type cell =
  | Null
  | Int64 of int64
  | Time of Time_ns.t
  | Sym of string
  | Str of string
  | F64 of float
  (** Null never becomes zero or an empty display string. Providers translate
    source-specific sentinels. Monetary source fields are Int64, not F64. *)

type schema_version =
  | Legacy_unversioned
  | Version of int

type provenance =
  { framework_revision : string
  ; snapshot_sha256 : string
  ; rayforce_binary_sha256 : string
  ; rayforce_version : string
  }

(** Exact decimal text, e.g. "0.00000001". Do not infer scales from a column name. *)
type decimal_scale =
  { currency : string
  ; cash_unit_decimal : string
  }

type instrument =
  { symbol : string
  ; multiplier : int64
  ; tick_decimal : string option
  ; lot_decimal : string option
  }

(** Legacy manifests do not provide all units or structured parameters. Missing
    metadata stays absent; opening a directory does not prove completion. *)
type completion =
  | Legacy_unverified
  | Validated_complete

type metric =
  { key : string
  ; label : string
  ; kind : field_kind
  ; value : cell
  }

type summary =
  { scope : scope
  ; evaluation_window : Time_range.t
  ; warmup_steps : int64
  ; return_period : Time_ns.Span.t
  ; periods_per_year : float
  ; risk_free_rate : float
  ; metrics : metric list
  ; assumptions : string list
  }

type buy_policy =
  | Scale
  | Reject

type parameter =
  | P_null
  | P_int of int64
  | P_float of float
  | P_bool of bool
  | P_string of string
  | P_symbol of string
  | P_timestamp of Time_ns.t
  | P_span of Time_ns.Span.t
  | P_list of parameter list
  | P_dict of (string * parameter) list

type config =
  { cash0 : int64
  ; fee_ppm : int64
  ; start : Time_ns.t
  ; period : Time_ns.Span.t
  ; steps : int64
  ; max_weight_ppm : int64
  ; max_gross_ppm : int64
  ; buy_policy : buy_policy
  }

type snapshot =
  { directory : string
  ; sha256sums_sha256 : string
  }

(** Proposed structured runner input, not yet accepted by run.sh. The runner
    remains responsible for semantic validation and recording effective values. *)
type run_spec =
  { version : int
  ; id : run_id
  ; strategy : strategy_id
  ; parameters : (string * parameter) list
  ; snapshot : snapshot
  ; config : config
  ; output_directory : string
  }

type run_info =
  { id : run_id
  ; schema_version : schema_version
  ; strategies : strategy_id list
  ; provenance : provenance
  ; cash_scale : decimal_scale option
  ; instruments : instrument list option
  ; specification : run_spec option
  ; effective_config : config option
  ; strategy_parameters : (strategy_id * (string * parameter) list) list option
  ; snapshot : snapshot option
  ; legacy_config_text : string option
  ; legacy_parameters_text : (strategy_id * string) list
  ; warnings : string list
  }

val table_filename : table -> string

(** The current CSV columns, in their exact export order. A fresh array each call. *)
val current_schema : table -> field array
