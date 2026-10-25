open Core
open Ctypes
open Backtest_shared
open Protocol
open Backtest_viewer
module B = Imguiml.Bindings
module T = Imguiml.Types

type geometry =
  { series : series
  ; range : Model.Time_range.t
  ; x : float
  ; y : float
  ; width : float
  ; height : float
  }

type prepared =
  { geometry : geometry
  ; segments : T.Vec2.t CArray.t list
  ; extent : string
  }

let cache = ref None

let vector x y =
  let p = make T.Vec2.t in
  setf p T.Vec2.x x;
  setf p T.Vec2.y y;
  p
;;

let same a b =
  phys_equal a.series b.series
  && phys_equal a.range b.range
  && Float.equal a.x b.x
  && Float.equal a.y b.y
  && Float.equal a.width b.width
  && Float.equal a.height b.height
;;

let prepare geometry =
  let g = geometry in
  let values =
    Array.filter_map g.series.points ~f:(fun p ->
      if Model.Time_range.contains g.range p.at then p.value else None)
  in
  match
    ( Array.min_elt values ~compare:Int64.compare
    , Array.max_elt values ~compare:Int64.compare )
  with
  | Some base, Some maximum ->
    let amplitude = Float.max 1. (Chart.relative maximum base) in
    let segment = ref []
    and segments = ref [] in
    let finish () =
      if not (List.is_empty !segment)
      then segments := CArray.of_list T.Vec2.t (List.rev !segment) :: !segments;
      segment := []
    in
    let add point =
      match point.value with
      | None -> finish ()
      | Some value ->
        let x = g.x +. (g.width *. Chart.fraction g.range point.at) in
        let y =
          g.y
          +. g.height
          -. 10.
          -. ((g.height -. 20.) *. Chart.relative value base /. amplitude)
        in
        segment := vector x y :: !segment
    in
    Array.iter g.series.points ~f:add;
    finish ();
    { geometry
    ; segments = List.rev !segments
    ; extent = sprintf "Raw extent: %Ld to %Ld" base maximum
    }
  | _ -> { geometry; segments = []; extent = "No non-null equity points" }
;;

let draw dl geometry =
  let prepared =
    match !cache with
    | Some cached when same cached.geometry geometry -> cached
    | _ ->
      let prepared = prepare geometry in
      cache := Some prepared;
      prepared
  in
  let draw points =
    if CArray.length points >= 2
    then
      B.ImDrawList.add_polyline
        dl
        (CArray.start points)
        (CArray.length points)
        0xffa9d970
        2.
        0
    else if CArray.length points = 1
    then B.ImDrawList.add_circle_filled dl (CArray.get points 0) 2. 0xffa9d970 6
  in
  B.ImDrawList.push_clip_rect
    dl
    (vector geometry.x geometry.y)
    (vector (geometry.x +. geometry.width) (geometry.y +. geometry.height))
    true;
  List.iter prepared.segments ~f:draw;
  B.ImDrawList.pop_clip_rect dl;
  prepared.extent
;;
