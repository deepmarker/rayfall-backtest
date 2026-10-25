open Core
open Backtest_shared
open Backtest_viewer

let check message condition = if not condition then failwith message
let time n = Time_ns.of_int63_ns_since_epoch (Int63.of_int64_exn n)

let range first last =
  Result.ok_or_failwith (Model.Time_range.make ~start:(time first) ~stop:(time last))
;;

let () =
  let full = range (-4_000_000_000_000_000_000L) 4_000_000_000_000_000_000L in
  let midpoint = Chart.time_at full 0.5 in
  check "interpolation across the full Time_ns range" (Time_ns.equal midpoint (time 0L));
  check
    "fraction across the full Time_ns range"
    (Float.equal (Chart.fraction full midpoint) 0.5);
  let zoomed =
    Chart.zoom full ~full_range:full ~anchor:0.5 ~factor:0.5 |> Result.ok_or_failwith
  in
  check "zoom shrinks" Time_ns.(zoomed.start_inclusive > full.start_inclusive);
  let restored =
    Chart.zoom zoomed ~full_range:full ~anchor:0.5 ~factor:2. |> Result.ok_or_failwith
  in
  check
    "zoom out restores full range"
    (Time_ns.equal restored.start_inclusive full.start_inclusive
     && Time_ns.equal restored.end_exclusive full.end_exclusive);
  let full_drag = range 0L 1000L
  and viewport = range 250L 750L in
  let drag = Chart.start_drag viewport ~x:100. ~y:50. in
  check
    "click jitter does not pan"
    (Option.is_none
       (Chart.drag_range
          drag
          ~full_range:full_drag
          ~x:102.
          ~y:51.
          ~width:500.
          ~threshold:6.));
  let moved =
    Chart.drag_range drag ~full_range:full_drag ~x:200. ~y:50. ~width:500. ~threshold:6.
    |> Option.value_exn
  in
  check
    "dragging right moves the visible window earlier"
    (Time_ns.equal moved.start_inclusive (time 150L));
  let moved_again =
    Chart.drag_range drag ~full_range:full_drag ~x:250. ~y:50. ~width:500. ~threshold:6.
    |> Option.value_exn
  in
  check
    "drag uses its original anchor without accumulating error"
    (Time_ns.equal moved_again.start_inclusive (time 100L));
  let clamped =
    Chart.drag_range drag ~full_range:full_drag ~x:1000. ~y:50. ~width:500. ~threshold:6.
    |> Option.value_exn
  in
  check
    "drag clamps at history start"
    (Time_ns.equal clamped.start_inclusive (time 0L)
     && Time_ns.equal clamped.end_exclusive (time 500L));
  ignore
    (Chart.drag_range drag ~full_range:full_drag ~x:100. ~y:50. ~width:500. ~threshold:6.);
  check "a drag that returns to its starting point stays a drag" drag.moved;
  check
    "money differences above float's exact range"
    (Float.equal (Chart.relative 9_007_199_254_740_993L 9_007_199_254_740_992L) 1.);
  check
    "int64 extremes do not wrap"
    Float.(Chart.relative Int64.max_value Int64.min_value > 0.);
  check
    "exact integer display"
    (String.equal
       (Controller.cell_text (Model.Int64 9_007_199_254_740_993L))
       "9007199254740993")
;;
