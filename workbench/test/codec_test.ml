open Core
open Backtest_shared
open Model
open Protocol
module V = Rayforce_ipc.Value
module Sym = Rayforce_ipc.Sym
module Codec = Backtest_reader.Codec

let dict fields =
  V.Dict
    ( V.Syms (Array.of_list_map fields ~f:(fun (name, _) -> Sym.intern name))
    , V.List (Array.of_list_map fields ~f:snd) )
;;

let scope = { run = "run"; strategy = "strategy" }

let q =
  { scope
  ; table = Equity
  ; interval = None
  ; instrument = None
  ; order_id = None
  ; sort = []
  ; offset = 0L
  ; limit = 1
  }
;;

let request = { id = 1L; generation = 2L; operation = Rows q }
let exact = 9007199254740993L

let data ?(cash = exact) ?(rows = 1) () =
  V.table
    [ "ts", V.Timestamps (Array.create ~len:rows 1L)
    ; "cash", V.Ints (Array.create ~len:rows cash)
    ; "mv", V.Ints (Array.create ~len:rows 0L)
    ; "equity", V.Ints (Array.create ~len:rows exact)
    ; "realized", V.Ints (Array.create ~len:rows 0L)
    ; "fees", V.Ints (Array.create ~len:rows 0L)
    ; "unrealized", V.Ints (Array.create ~len:rows 0L)
    ; "wb_row", V.Ints (Array.create ~len:rows 0L)
    ]
;;

let reply ?(id = 1L) ?(version = 1L) payload =
  dict
    [ "version", V.Int version
    ; "id", V.Int id
    ; "generation", V.Int 2L
    ; "status", V.String "ok"
    ; "payload", payload
    ]
;;

let page data total = dict [ "data", data; "total_rows", V.Int total ]

let invalid = function
  | Error (Invalid_output _) -> true
  | _ -> false
;;

let () =
  (match Codec.decode request (reply (page (data ()) 1L)) with
   | Ok (Page p) ->
     assert (
       match p.rows.(0).cells.(1) with
       | Int64 n -> Int64.equal n exact
       | _ -> false);
     assert (
       match p.rows.(0).cells.(0) with
       | Time at -> Int64.equal (Rayforce_ipc.Timestamp.of_time_ns_int64 at) 1L
       | _ -> false)
   | _ -> assert false);
  assert (invalid (Codec.decode request (reply ~id:2L (page (data ()) 1L))));
  assert (invalid (Codec.decode request (reply (page (data ~rows:2 ()) 2L))));
  assert (invalid (Codec.decode request (reply (page (data ~cash:Int64.min_value ()) 1L))));
  assert (invalid (Codec.decode request (reply (page (data ()) (-1L)))));
  assert (invalid (Codec.decode request (reply (page (data ()) 0L))));
  assert (invalid (Codec.decode request (V.Error "domain")));
  assert (invalid (Codec.decode request (reply (page V.Null 0L))));
  assert (
    invalid
      (Codec.decode
         { request with operation = Rows { q with limit = 2 } }
         (reply (page (data ~rows:2 ()) 2L))));
  (match Codec.decode request (reply ~version:99L V.Null) with
   | Error (Unsupported_version 99) -> ()
   | _ -> assert false);
  assert (
    Result.is_error
      (validate (Rows { q with scope = { scope with strategy = "bad\000name" } })));
  assert (
    Result.is_error
      (validate (Rows { q with table = Positions; instrument = Some "bad\000name" })))
;;
