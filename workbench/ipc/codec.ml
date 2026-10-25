open Core
open Backtest_shared
open Model
open Protocol
module V = Rayforce_ipc.Value
module Sym = Rayforce_ipc.Sym

exception Bad_reply of string
exception Bad_version of int

let bad message = raise (Bad_reply message)
let sym text = V.Sym (Sym.intern text)

let dict fields =
  V.Dict
    ( V.Syms (Array.of_list_map fields ~f:(fun (key, _) -> Sym.intern key))
    , V.List (Array.of_list_map fields ~f:snd) )
;;

let optional encode = function
  | None -> V.Null
  | Some value -> encode value
;;

let time at = V.Timestamp (Rayforce_ipc.Timestamp.of_time_ns_int64 at)

let interval_fields = function
  | None -> [ "start", V.Null; "stop", V.Null ]
  | Some range ->
    [ "start", time range.Time_range.start_inclusive; "stop", time range.end_exclusive ]
;;

let table_name table = Filename.chop_extension (table_filename table)

let encode (request : request) =
  let base =
    [ "version", V.Int 1L
    ; "id", V.Int request.id
    ; "generation", V.Int request.generation
    ]
  in
  let scope_fields (scope : scope) =
    [ "run", V.String scope.run; "strategy", sym scope.strategy ]
  in
  let fields =
    match request.operation with
    | Describe run -> [ "op", V.String "describe"; "run", V.String run ]
    | Summary scope -> ("op", V.String "summary") :: scope_fields scope
    | Rows q ->
      [ "op", V.String "rows"
      ; "table", sym (table_name q.table)
      ; "instrument", optional sym q.instrument
      ; "order_id", optional (fun n -> V.Int n) q.order_id
      ; "offset", V.Int q.offset
      ; "limit", V.Int (Int64.of_int q.limit)
      ; "sort", V.Syms (Array.of_list_map q.sort ~f:(fun (name, _) -> Sym.intern name))
      ; ( "descending"
        , V.Bools
            (Array.of_list_map q.sort ~f:(fun (_, dir) ->
               match dir with
               | Descending -> true
               | Ascending -> false)) )
      ]
      @ scope_fields q.scope
      @ interval_fields q.interval
    | Series q ->
      [ "op", V.String "series"
      ; "table", sym (table_name q.table)
      ; "field", sym q.field
      ; "instrument", optional sym q.instrument
      ; "order_id", V.Null
      ; "pixel_width", V.Int (Int64.of_int q.pixel_width)
      ; "max_points", V.Int (Int64.of_int q.max_points)
      ]
      @ scope_fields q.scope
      @ interval_fields (Some q.interval)
  in
  dict (base @ fields)
;;

let atom vector i =
  match vector with
  | V.List a -> a.(i)
  | V.Ints a -> V.Int a.(i)
  | V.Bools a -> V.Bool a.(i)
  | V.Timespans a -> V.Timespan a.(i)
  | V.Timestamps a -> V.Timestamp a.(i)
  | V.Syms a -> V.Sym a.(i)
  | V.Strings a -> V.String a.(i)
  | V.Floats a -> V.Float a.(i)
  | _ -> bad "expected a supported vector"
;;

let members = function
  | V.Dict (V.Syms keys, values) ->
    if Array.length keys <> V.length values then bad "dictionary lengths differ";
    let names = Array.map keys ~f:Sym.to_string in
    if List.contains_dup (Array.to_list names) ~compare:String.compare
    then bad "duplicate dictionary keys";
    Array.to_list (Array.mapi names ~f:(fun i name -> name, atom values i))
  | _ -> bad "expected dictionary"
;;

let get fields name =
  match List.Assoc.find fields name ~equal:String.equal with
  | Some value -> value
  | None -> bad ("missing field: " ^ name)
;;

let string = function
  | V.String s -> s
  | _ -> bad "expected string"
;;

let integer = function
  | V.Int n -> n
  | _ -> bad "expected int64"
;;

let number = function
  | V.Float n when Float.is_finite n -> n
  | _ -> bad "expected finite float"
;;

let timestamp = function
  | V.Timestamp n ->
    (match Rayforce_ipc.Timestamp.to_time_ns_int64 n with
     | Ok t -> t
     | Error e -> bad e)
  | _ -> bad "expected timestamp"
;;

let strings = function
  | V.List a -> List.map (Array.to_list a) ~f:string
  | V.Strings a -> Array.to_list a
  | _ -> bad "expected string list"
;;

let symbols = function
  | V.Syms a -> List.map (Array.to_list a) ~f:Sym.to_string
  | _ -> bad "expected symbols"
;;

let int_bound n ~min:lower ~max:upper =
  if Int64.(n < of_int lower || n > of_int upper)
  then bad "integer outside reply bounds"
  else Int64.to_int_exn n
;;

let cell field value =
  let null () = if field.nullable then Null else bad ("unexpected null: " ^ field.name) in
  match field.kind, value with
  | _, V.Null -> null ()
  | Integer _, V.Int n -> if Int64.equal n Int64.min_value then null () else Int64 n
  | Timestamp_ns, V.Timestamp n ->
    if Int64.equal n Int64.min_value then null () else Time (timestamp value)
  | Symbol, V.Sym name ->
    let name = Sym.to_string name in
    if String.is_empty name && field.nullable then Null else Sym name
  | Text, V.String text -> Str text
  | Float, V.Float n ->
    if Float.is_nan n
    then null ()
    else if Float.is_finite n
    then F64 n
    else bad "non-finite value"
  | _ -> bad ("wrong column type: " ^ field.name)
;;

let table fields ~limit = function
  | V.Table columns as value ->
    if Array.length columns <> Array.length fields + 1 then bad "unexpected table columns";
    Array.iteri fields ~f:(fun i field ->
      if not (String.equal (Sym.to_string columns.(i).name) field.name)
      then bad "table schema mismatch");
    let ids = columns.(Array.length fields) in
    if not (String.equal (Sym.to_string ids.name) "wb_row")
    then bad "missing physical row IDs";
    let count = V.nrows value in
    if count > limit then bad "reply exceeds requested row budget";
    let seen = Hash_set.create (module Int64) in
    Array.init count ~f:(fun i ->
      let id = integer (atom ids.data i) in
      if Int64.(id < 0L) || Hash_set.mem seen id
      then bad "invalid/duplicate physical row ID";
      Hash_set.add seen id;
      id, Array.mapi fields ~f:(fun k field -> cell field (atom columns.(k).data i)))
  | _ -> bad "expected table"
;;

let span = function
  | V.Timespan ns ->
    (match Rayforce_ipc.Timespan.to_span ns with
     | Ok span -> span
     | Error e -> bad e)
  | _ -> bad "expected timespan"
;;

let rec parameter ?(depth = 0) value =
  if depth > 32 then bad "parameter nesting limit exceeded";
  let nested value = parameter ~depth:(depth + 1) value in
  match value with
  | V.Null -> P_null
  | V.Bool b -> P_bool b
  | V.Int n -> P_int n
  | V.Float f when Float.is_finite f -> P_float f
  | V.String s -> P_string s
  | V.Sym s -> P_symbol (Sym.to_string s)
  | V.Timestamp _ -> P_timestamp (timestamp value)
  | V.Timespan _ -> P_span (span value)
  | V.Dict _ -> P_dict (List.map (members value) ~f:(fun (k, v) -> k, nested v))
  | V.List _
  | V.Ints _
  | V.Floats _
  | V.Bools _
  | V.Syms _
  | V.Strings _
  | V.Timestamps _
  | V.Timespans _ ->
    P_list (List.init (V.length value) ~f:(fun i -> nested (atom value i)))
  | _ -> bad "unsupported parameter value"
;;

let configuration value =
  let fields = members value in
  let int name = integer (get fields name) in
  let period = span (get fields "period") in
  if Time_ns.Span.(period <= zero) then bad "nonpositive configuration period";
  let buy_policy =
    match get fields "buy_policy" with
    | V.Sym s when String.equal (Sym.to_string s) "SCALE" -> Scale
    | V.Sym s when String.equal (Sym.to_string s) "REJECT" -> Reject
    | _ -> bad "invalid buy policy"
  in
  { cash0 = int "cash0"
  ; fee_ppm = int "fee_ppm"
  ; start = timestamp (get fields "start")
  ; period
  ; steps = int "steps"
  ; max_weight_ppm = int "max_weight_ppm"
  ; max_gross_ppm = int "max_gross_ppm"
  ; buy_policy
  }
;;

let decimal value =
  let text = string value in
  let parts = String.split text ~on:'.' in
  let digits s = (not (String.is_empty s)) && String.for_all s ~f:Char.is_digit in
  if
    List.length parts > 2
    || (not (List.for_all parts ~f:digits))
    || not (String.exists text ~f:(fun c -> Char.(c >= '1' && c <= '9')))
  then bad "expected positive exact decimal text";
  text
;;

let nullable decode = function
  | V.Null -> None
  | value -> Some (decode value)
;;

let cash_scale value =
  let fields = members value in
  { currency = string (get fields "currency")
  ; cash_unit_decimal = decimal (get fields "cash_unit_decimal")
  }
;;

let instruments = function
  | V.List values ->
    let instrument value =
      let fields = members value in
      let symbol = string (get fields "symbol") in
      let multiplier = integer (get fields "multiplier") in
      if String.is_empty symbol || Int64.(multiplier <= 0L) then bad "invalid instrument";
      { symbol
      ; multiplier
      ; tick_decimal = nullable decimal (get fields "tick_decimal")
      ; lot_decimal = nullable decimal (get fields "lot_decimal")
      }
    in
    let values = Array.to_list (Array.map values ~f:instrument) in
    if List.contains_dup (List.map values ~f:(fun i -> i.symbol)) ~compare:String.compare
    then bad "duplicate instrument";
    values
  | _ -> bad "expected instrument list"
;;

let describe run payload =
  let fields = members payload in
  let metadata = members (get fields "metadata") in
  let str name = string (get metadata name) in
  let parameters =
    members (get metadata "parameter_text")
    |> List.map ~f:(fun (name, value) -> name, string value)
  in
  let strategies = symbols (get fields "strategies") in
  if
    List.is_empty strategies
    || List.exists strategies ~f:String.is_empty
    || List.contains_dup strategies ~compare:String.compare
  then bad "invalid strategies";
  let details =
    Option.value (List.Assoc.find fields "bundle" ~equal:String.equal) ~default:V.Null
  in
  let ( schema_version
      , completion
      , effective_config
      , strategy_parameters
      , snapshot
      , cash_scale
      , instruments
      , warnings )
    =
    match details with
    | V.Null ->
      ( Legacy_unversioned
      , Legacy_unverified
      , None
      , None
      , None
      , None
      , None
      , [ "In-memory snapshot; durable publication and display scales remain unverified."
        ] )
    | details ->
      let details = members details in
      let version =
        int_bound (integer (get details "version")) ~min:0 ~max:Int.max_value
      in
      if version <> 1 then raise (Bad_version version);
      let config = configuration (get details "effective_config") in
      let params =
        members (get details "parameters")
        |> List.map ~f:(fun (s, v) ->
          match parameter v with
          | P_dict fields -> s, fields
          | _ -> bad "strategy parameters must be a dictionary")
      in
      if
        not
          (List.equal
             String.equal
             (List.sort strategies ~compare:String.compare)
             (List.sort (List.map params ~f:fst) ~compare:String.compare))
      then bad "parameter strategy mismatch";
      let snap = members (get details "snapshot") in
      let snapshot =
        { directory = string (get snap "directory")
        ; sha256sums_sha256 = string (get snap "sha256sums_sha256")
        }
      in
      if not (String.equal snapshot.sha256sums_sha256 (str "snapshot_sha256"))
      then bad "snapshot identity mismatch";
      let scales = nullable cash_scale (get details "cash_scale") in
      let instrument_metadata = nullable instruments (get details "instruments") in
      let warnings =
        if Option.is_none scales || Option.is_none instrument_metadata
        then [ "Some display scales are absent; show raw labeled units." ]
        else []
      in
      ( Version 1
      , Validated_complete
      , Some config
      , Some params
      , Some snapshot
      , scales
      , instrument_metadata
      , warnings )
  in
  let info =
    { id = run
    ; schema_version
    ; strategies
    ; provenance =
        { framework_revision = str "framework_revision"
        ; snapshot_sha256 = str "snapshot_sha256"
        ; rayforce_binary_sha256 = str "rayforce_binary_sha256"
        ; rayforce_version = str "rayforce_version"
        }
    ; cash_scale
    ; instruments
    ; specification = None
    ; effective_config
    ; strategy_parameters
    ; snapshot
    ; legacy_config_text = Some (str "config_text")
    ; legacy_parameters_text = parameters
    ; warnings
    }
  in
  Run_info (info, completion)
;;

let summary scope payload =
  let fields = members payload in
  let start = timestamp (get fields "start")
  and stop = timestamp (get fields "stop") in
  let evaluation_window =
    match Time_range.make ~start ~stop with
    | Ok range -> range
    | Error e -> bad e
  in
  let warmup_steps = integer (get fields "warmup") in
  if Int64.(warmup_steps < 0L) then bad "negative warmup";
  let period_ns =
    match get fields "period" with
    | V.Timespan ns -> ns
    | _ -> bad "expected timespan period"
  in
  if Int64.(period_ns <= 0L) then bad "nonpositive return period";
  let return_period =
    match Rayforce_ipc.Timespan.to_span period_ns with
    | Ok span -> span
    | Error e -> bad e
  in
  let metric (key, value) =
    let kind, value =
      match value with
      | V.Int n when not (Int64.equal n Int64.min_value) -> Integer Counter, Int64 n
      | V.Float n ->
        ( Float
        , if Float.is_nan n
          then Null
          else if Float.is_finite n
          then F64 n
          else bad "infinite metric" )
      | _ -> bad "invalid metric value"
    in
    { key; label = key; kind; value }
  in
  let periods_per_year = number (get fields "periods_per_year") in
  if Float.(periods_per_year <= 0.) then bad "nonpositive annualisation factor";
  Summary_data
    { scope
    ; evaluation_window
    ; warmup_steps
    ; return_period
    ; periods_per_year
    ; risk_free_rate = number (get fields "risk_free_rate")
    ; metrics = List.map (members (get fields "metrics")) ~f:metric
    ; assumptions = strings (get fields "assumptions")
    }
;;

let page (q : row_query) payload =
  let payload = members payload in
  let fields = current_schema q.table in
  let rows =
    table fields ~limit:q.limit (get payload "data")
    |> Array.map ~f:(fun (source_row, cells) ->
      { id = { scope = q.scope; table = q.table; source_row }; cells })
  in
  let total = integer (get payload "total_rows") in
  if Int64.(total < 0L) then bad "negative filtered total";
  let expected =
    Int64.(min (of_int q.limit) (max 0L (total - min total q.offset))) |> Int64.to_int_exn
  in
  if Array.length rows <> expected then bad "inconsistent page size/total";
  Page
    { scope = q.scope
    ; table = q.table
    ; fields
    ; rows
    ; offset = q.offset
    ; total_rows = Some total
    }
;;

let series (q : series_query) payload =
  let payload = members payload in
  let field =
    Array.find_exn (current_schema q.table) ~f:(fun field ->
      String.equal field.name q.field)
  in
  let fields =
    [| { name = "ts"; kind = Timestamp_ns; nullable = false }
     ; { field with name = "value" }
    |]
  in
  (* The wire table puts its physical ID first. Normalize before strict decode. *)
  let data =
    match get payload "data" with
    | V.Table a
      when Array.length a = 3 && String.equal (Sym.to_string a.(0).name) "wb_row" ->
      V.Table [| a.(1); a.(2); a.(0) |]
    | _ -> bad "invalid series schema"
  in
  let points =
    table fields ~limit:q.max_points data
    |> Array.map ~f:(fun (source_row, cells) ->
      let at =
        match cells.(0) with
        | Time at -> at
        | _ -> bad "invalid series time"
      in
      if not (Time_range.contains q.interval at) then bad "series time outside interval";
      let value =
        match cells.(1) with
        | Int64 n -> Some n
        | Null -> None
        | _ -> bad "invalid series value"
      in
      { record = { scope = q.scope; table = q.table; source_row }; at; value })
  in
  for i = 1 to Array.length points - 1 do
    let previous = points.(i - 1)
    and current = points.(i) in
    let cmp = Time_ns.compare previous.at current.at in
    if
      cmp > 0
      || (cmp = 0 && Int64.(previous.record.source_row >= current.record.source_row))
    then bad "series is out of order"
  done;
  let source_points = integer (get payload "source_points") in
  let buckets = int_bound (integer (get payload "buckets")) ~min:0 ~max:q.pixel_width in
  let sampling =
    if buckets = 0
    then (
      if not (Int64.equal source_points (Int64.of_int (Array.length points)))
      then bad "invalid exact series count";
      Exact)
    else (
      if Int64.(source_points <= of_int q.max_points)
      then bad "invalid sampled series count";
      Extrema_envelope { source_points; buckets })
  in
  Series_data { scope = q.scope; field; interval = q.interval; points; sampling }
;;

let decode (request : request) value =
  try
    (match value with
     | V.Error code -> bad ("Rayforce error: " ^ code)
     | _ -> ());
    let fields = members value in
    let version = integer (get fields "version") in
    if not (Int64.equal version 1L)
    then Error (Unsupported_version (int_bound version ~min:0 ~max:Int.max_value))
    else if
      not
        (Int64.equal (integer (get fields "id")) request.id
         && Int64.equal (integer (get fields "generation")) request.generation)
    then bad "reply correlation mismatch"
    else (
      let payload = get fields "payload" in
      match string (get fields "status") with
      | "ok" ->
        Ok
          (match request.operation with
           | Describe run -> describe run payload
           | Summary scope -> summary scope payload
           | Rows q -> page q payload
           | Series q -> series q payload)
      | "invalid" -> Error (Invalid_request (string payload))
      | "unavailable" -> Error (Unavailable (string payload))
      | "unsupported" ->
        Error
          (Unsupported_version (int_bound (integer payload) ~min:0 ~max:Int.max_value))
      | _ -> bad "unknown reply status")
  with
  | Bad_version version -> Error (Unsupported_version version)
  | Bad_reply message -> Error (Invalid_output message)
  | exn -> Error (Invalid_output (Exn.to_string exn))
;;

let decode_run_info ~run payload =
  try
    match describe run payload with
    | Run_info (info, completion) -> Ok (info, completion)
    | _ -> assert false
  with
  | Bad_version version -> Error (Unsupported_version version)
  | Bad_reply message -> Error (Invalid_output message)
  | exn -> Error (Invalid_output (Exn.to_string exn))
;;
