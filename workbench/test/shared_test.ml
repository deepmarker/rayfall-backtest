open Core
open Backtest_shared
open Model
open Protocol

let get = function
  | Ok v -> v
  | Error _ -> failwith "unexpected error"
;;

let time n = Time_ns.of_int63_ns_since_epoch (Int63.of_int64_exn n)
let scope = { run = "fixture"; strategy = "trend" }
let interval = get (Time_range.make ~start:(time 0L) ~stop:(time 10L))

let rejected = function
  | Error _ -> true
  | Ok _ -> false
;;

let () =
  assert (rejected (Time_range.make ~start:(time 1L) ~stop:(time 1L)));
  assert (Time_range.contains interval (time 0L));
  assert (not (Time_range.contains interval (time 10L)));
  let query =
    { scope
    ; table = Equity
    ; interval = None
    ; instrument = None
    ; order_id = None
    ; sort = [ "ts", Ascending ]
    ; offset = 0L
    ; limit = 100
    }
  in
  assert (Result.is_ok (validate (Rows query)));
  assert (rejected (validate (Rows { query with order_id = Some 1L })));
  assert (rejected (validate (Rows { query with offset = -1L })));
  assert (rejected (validate (Rows { query with limit = 10001 })));
  assert (rejected (validate (Rows { query with sort = [ "execute", Ascending ] })));
  let q =
    { scope
    ; table = Equity
    ; field = "equity"
    ; interval
    ; instrument = None
    ; pixel_width = 800
    ; max_points = 3200
    }
  in
  assert (Result.is_ok (validate (Series q)));
  assert (rejected (validate (Series { q with max_points = 0 })));
  assert (rejected (validate (Series { q with max_points = 65537 })));
  assert (rejected (validate (Series { q with field = "ts" })));
  assert (rejected (validate (Series { q with table = Positions; field = "qty" })));
  assert (
    Result.is_ok
      (validate
         (Series { q with table = Positions; field = "qty"; instrument = Some "BTCUSDT" })));
  let stale = { id = 7L; generation = 1L; result = Error Cancelled } in
  assert (not (is_current ~generation:2L stale));
  let fields = current_schema Equity in
  assert (
    List.equal
      String.equal
      (Array.to_list (Array.map fields ~f:(fun f -> f.name)))
      [ "ts"; "cash"; "mv"; "equity"; "realized"; "fees"; "unrealized" ]);
  fields.(0) <- { name = "changed"; kind = Text; nullable = false };
  assert (String.equal (current_schema Equity).(0).name "ts")
;;

let tables =
  [ Targets; Orders; Order_events; Fills; Ledger; Positions; Equity; Attribution ]
;;

let check_fixture_header table =
  let path = Filename.concat "fixtures/fixture1" (table_filename table) in
  let header = In_channel.with_file path ~f:In_channel.input_line_exn in
  let actual = String.split (String.strip header) ~on:',' in
  let expected =
    Array.to_list (Array.map (current_schema table) ~f:(fun field -> field.name))
  in
  if not (List.equal String.equal actual expected)
  then failwith ("fixture schema mismatch: " ^ path)
;;

let () = List.iter tables ~f:check_fixture_header
