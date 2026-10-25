open Core
open Ctypes
open Backtest_shared
open Backtest_viewer
module B = Imguiml.Bindings
module T = Imguiml.Types
module C = Controller

let drag : (C.t * Chart.drag) option ref = ref None
let active c = Option.exists !drag ~f:(fun (owner, _) -> phys_equal owner c)

let handle c ~series ~range ~x ~y:_ ~width ~hovered ~activated =
  if Option.exists !drag ~f:(fun (owner, _) -> not (phys_equal owner c)) then drag := None;
  let mouse = B.get_mouse_pos () in
  let mouse_x = getf mouse T.Vec2.x
  and mouse_y = getf mouse T.Vec2.y in
  if activated then drag := Some (c, Chart.start_drag range ~x:mouse_x ~y:mouse_y);
  let fraction = Float.clamp_exn ((mouse_x -. x) /. width) ~min:0. ~max:1. in
  (match !drag, c.C.full_range with
   | Some (owner, gesture), Some full_range when phys_equal owner c ->
     let threshold = !@(B.get_io_nil () |-> T.Io.mouse_drag_threshold) in
     Option.iter
       (Chart.drag_range gesture ~full_range ~x:mouse_x ~y:mouse_y ~width ~threshold)
       ~f:(C.set_range c);
     if B.is_mouse_released_nil 0
     then (
       if (not gesture.moved) && hovered
       then
         Option.iter
           (Chart.nearest series.Protocol.points range fraction)
           ~f:(fun point -> C.set_cursor c point.at);
       drag := None)
     else if not (B.is_mouse_down_nil 0)
     then drag := None
   | _ -> ());
  if hovered && not (active c)
  then (
    let wheel = !@(B.get_io_nil () |-> T.Io.mouse_wheel) in
    if not (Float.equal wheel 0.)
    then
      Option.iter c.range ~f:(fun selected ->
        Option.iter c.full_range ~f:(fun full_range ->
          Result.iter
            (Chart.zoom
               selected
               ~full_range
               ~anchor:fraction
               ~factor:(if Float.(wheel > 0.) then 0.7 else 1.4))
            ~f:(C.set_range c)));
    Option.iter (Chart.nearest series.points range fraction) ~f:(fun point ->
      if B.begin_tooltip ()
      then (
        B.text_unformatted (Time_ns.to_string_utc point.at) None;
        B.text_unformatted
          ("Equity: " ^ Option.value_map point.value ~default:"null" ~f:Int64.to_string)
          None;
        B.text_unformatted (sprintf "Source row: %Ld" point.record.source_row) None;
        B.end_tooltip ())))
;;

(* Exercise the real ImGui mouse-event path in GUI smoke tests. *)
let testing = ref false
let test_stage = ref 0
let last_plot = ref None
let test_range = ref None
let test_cursor = ref None
let test_controller = ref None
let finished () = !test_stage >= 7

let record_plot c ~x ~y ~width ~height =
  let center_y = y +. (height *. 0.5) in
  let dl = B.get_window_draw_list () in
  let clip_min = B.ImDrawList.get_clip_rect_min dl
  and clip_max = B.ImDrawList.get_clip_rect_max dl in
  let visible =
    Float.(center_y >= getf clip_min T.Vec2.y && center_y < getf clip_max T.Vec2.y)
  in
  last_plot := if visible then Some (x +. (width *. 0.5), center_y, width) else None;
  if !testing && (not (finished ())) && not visible then B.set_scroll_here_y 0.5;
  if
    !testing
    && !test_stage = 0
    && Option.is_none !test_controller
    && Option.is_some c.C.page
  then
    Option.iter c.full_range ~f:(fun full_range ->
      let zoomed =
        Chart.zoom full_range ~full_range ~anchor:0.5 ~factor:0.5 |> Result.ok_or_failwith
      in
      C.set_range c zoomed;
      test_range := Some zoomed;
      test_cursor := c.cursor;
      test_controller := Some c;
      test_stage := -2)
;;

let inject_events () =
  match !last_plot with
  | None -> ()
  | Some (x, y, width) ->
    let io = B.get_io_nil () in
    (match !test_stage with
     | -2 | -1 -> incr test_stage
     | 0 when Option.is_some !test_controller -> test_stage := 1
     | 1 ->
       B.ImGuiIO.add_focus_event io true;
       B.ImGuiIO.add_mouse_pos_event io x y;
       B.ImGuiIO.add_mouse_button_event io 0 true;
       test_stage := 2
     | 2 ->
       B.ImGuiIO.add_mouse_pos_event io (x +. (width *. 0.15)) y;
       test_stage := 3
     | 3 ->
       B.ImGuiIO.add_mouse_button_event io 0 false;
       test_stage := 4
     | 4 | 5 -> incr test_stage
     | 6 ->
       let c = Option.value_exn !test_controller in
       let before = Option.value_exn !test_range in
       let after = Option.value_exn c.range in
       if not Time_ns.(after.start_inclusive < before.start_inclusive)
       then failwith "Mouse drag did not pan the chart";
       if not (Option.equal Time_ns.equal c.cursor !test_cursor)
       then failwith "Mouse drag changed the record cursor";
       test_stage := 7
     | _ -> ())
;;
