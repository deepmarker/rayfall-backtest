open Core
open Backtest_shared
open Protocol

let ns t = Int63.to_int64 (Time_ns.to_int63_ns_since_epoch t)

let fraction range at =
  let first = ns range.Model.Time_range.start_inclusive in
  let width = Int64.(ns range.end_exclusive - first) in
  Float.of_int64 Int64.(ns at - first) /. Float.of_int64 width
;;

let time_at range fraction =
  if Float.(fraction <= 0.)
  then range.Model.Time_range.start_inclusive
  else if Float.(fraction >= 1.)
  then range.end_exclusive
  else (
    let first = ns range.start_inclusive in
    let width = Int64.(ns range.end_exclusive - first) in
    let offset =
      Float.of_int64 width *. fraction |> Float.round_nearest |> Int64.of_float
    in
    Time_ns.of_int63_ns_since_epoch (Int63.of_int64_exn Int64.(first + offset)))
;;

let nearest points range x =
  Array.filter points ~f:(fun point -> Model.Time_range.contains range point.at)
  |> Array.min_elt ~compare:(fun a b ->
    Float.compare
      (Float.abs (fraction range a.at -. x))
      (Float.abs (fraction range b.at -. x)))
;;

let relative value origin =
  let difference = Int64.(value - origin) in
  let overflow =
    Int64.(
      (origin > 0L && value < 0L && difference > 0L)
      || (origin < 0L && value >= 0L && difference < 0L))
  in
  if overflow
  then Float.of_int64 value -. Float.of_int64 origin
  else Float.of_int64 difference
;;

let zoom range ~full_range ~anchor ~factor =
  let first = fraction full_range range.Model.Time_range.start_inclusive in
  let last = fraction full_range range.end_exclusive in
  let width = Float.min 1. ((last -. first) *. factor) in
  let center = first +. ((last -. first) *. anchor) in
  let left = Float.clamp_exn (center -. (width *. anchor)) ~min:0. ~max:(1. -. width) in
  Model.Time_range.make
    ~start:(time_at full_range left)
    ~stop:(time_at full_range (left +. width))
;;

let pan range ~full_range ~fraction:shift =
  let left = fraction full_range range.Model.Time_range.start_inclusive in
  let right = fraction full_range range.end_exclusive in
  let width = right -. left in
  let first = Float.clamp_exn (left +. (width *. shift)) ~min:0. ~max:(1. -. width) in
  Model.Time_range.make
    ~start:(time_at full_range first)
    ~stop:(time_at full_range (first +. width))
;;

type drag =
  { initial_range : Model.Time_range.t
  ; press_x : float
  ; press_y : float
  ; mutable moved : bool
  }

let start_drag initial_range ~x ~y =
  { initial_range; press_x = x; press_y = y; moved = false }
;;

let drag_range drag ~full_range ~x ~y ~width ~threshold =
  let dx = x -. drag.press_x
  and dy = y -. drag.press_y in
  if Float.((dx *. dx) +. (dy *. dy) >= threshold *. threshold) then drag.moved <- true;
  if drag.moved && Float.(width > 0.)
  then Result.ok (pan drag.initial_range ~full_range ~fraction:(-.dx /. width))
  else None
;;
