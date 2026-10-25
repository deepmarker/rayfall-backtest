open Core
open Async
open Ctypes
open Backtest_shared
open Model
open Protocol
open Backtest_viewer
module B = Imguiml.Bindings
module T = Imguiml.Types
module C = Controller

let v x y =
  let p = make T.Vec2.t in
  setf p T.Vec2.x x;
  setf p T.Vec2.y y;
  p
;;

let flag = Int64.to_int_exn
let text s = B.text_unformatted s None
let button label = B.button label (v 0. 0.)
let same () = B.same_line 0. (-1.)

let toolbar_same () =
  if Float.(B.get_window_width () > B.get_font_size () *. 40.) then same ()
;;

let paragraph value =
  B.push_text_wrap_pos 0.;
  text value;
  B.pop_text_wrap_pos ()
;;

let child title width height draw =
  let visible = B.begin_child_str title (v width height) (flag T.ChildFlags.borders) 0 in
  if visible then draw ();
  B.end_child ()
;;

let table_name = function
  | Targets -> "Targets"
  | Orders -> "Orders"
  | Order_events -> "Order events"
  | Fills -> "Fills"
  | Ledger -> "Ledger"
  | Positions -> "Positions"
  | Equity -> "Equity"
  | Attribution -> "Attribution"
;;

let tables =
  [ Targets; Orders; Order_events; Fills; Ledger; Positions; Equity; Attribution ]
;;

let choose label current choices name select =
  B.begin_disabled (List.is_empty choices);
  let preview = if List.is_empty choices then "No choices available" else name current in
  if B.begin_combo label preview 0
  then (
    List.iter choices ~f:(fun value ->
      if
        B.selectable_bool
          (name value)
          (String.equal (name current) (name value))
          0
          (v 0. 0.)
      then select value);
    B.end_combo ());
  B.end_disabled ()
;;

let provenance c =
  let info = c.C.session.info in
  text ("Run: " ^ info.id);
  choose "Strategy" c.strategy info.strategies Fn.id (C.select_strategy c);
  B.separator_text "Provenance";
  text ("Framework: " ^ info.provenance.framework_revision);
  text ("Rayforce: " ^ info.provenance.rayforce_version);
  text ("Snapshot: " ^ info.provenance.snapshot_sha256);
  text ("Engine SHA256: " ^ info.provenance.rayforce_binary_sha256);
  Option.iter info.cash_scale ~f:(fun scale ->
    text ("Cash unit: " ^ scale.cash_unit_decimal ^ " " ^ scale.currency));
  List.iter info.warnings ~f:text;
  B.separator_text "Engine summary";
  match c.summary with
  | None -> text "Loading summary..."
  | Some summary ->
    text ("Evaluation: " ^ Time_ns.to_string_utc summary.evaluation_window.start_inclusive);
    text ("Until: " ^ Time_ns.to_string_utc summary.evaluation_window.end_exclusive);
    List.iter summary.metrics ~f:(fun metric ->
      text (metric.label ^ ": " ^ C.cell_text metric.value));
    List.iter summary.assumptions ~f:text
;;

let change_zoom c anchor factor =
  match c.C.range, c.full_range with
  | Some range, Some full_range ->
    (match Chart.zoom range ~full_range ~anchor ~factor with
     | Ok next -> C.set_range c next
     | Error _ -> ())
  | _ -> ()
;;

let chart c =
  if button "Zoom in" then change_zoom c 0.5 0.5;
  toolbar_same ();
  if button "Zoom out" then change_zoom c 0.5 2.;
  toolbar_same ();
  let pan label fraction =
    let next =
      Option.bind c.range ~f:(fun range ->
        Option.bind c.full_range ~f:(fun full_range ->
          match Chart.pan range ~full_range ~fraction with
          | Ok next when not (C.same_range range next) -> Some next
          | _ -> None))
    in
    B.begin_disabled (Option.is_none next);
    if button label then Option.iter next ~f:(C.set_range c);
    B.end_disabled ()
  in
  pan "Earlier" (-0.5);
  toolbar_same ();
  pan "Later" 0.5;
  toolbar_same ();
  if button "Reset" then Option.iter c.C.full_range ~f:(C.set_range c);
  match c.C.series with
  | Some series ->
    let range = Option.value c.range ~default:series.interval in
    paragraph
      (Time_ns.to_string_utc range.start_inclusive
       ^ " to "
       ^ Time_ns.to_string_utc range.end_exclusive);
    let sampling =
      match series.sampling with
      | Exact -> "Exact source points"
      | Extrema_envelope { source_points; buckets } ->
        sprintf "Extrema envelope: %Ld source points, %d buckets" source_points buckets
    in
    let help =
      if Option.exists c.full_range ~f:(C.same_range range)
      then "wheel: zoom, click: select; zoom in to pan"
      else "wheel: zoom, drag: pan, click: select"
    in
    paragraph (sampling ^ " | raw cash units | " ^ help ^ "; blue line: selected time");
    let origin = B.get_cursor_screen_pos () in
    let avail = B.get_content_region_avail () in
    let x = getf origin T.Vec2.x
    and y = getf origin T.Vec2.y in
    let width = Float.max 30. (getf avail T.Vec2.x)
    and height = Float.max 30. (getf avail T.Vec2.y -. 30.) in
    ignore (B.invisible_button "equity-plot" (v width height) 0 : bool);
    let hovered = B.is_item_hovered 0 in
    let activated = B.is_item_activated () in
    let dl = B.get_window_draw_list () in
    B.ImDrawList.add_rect_filled dl (v x y) (v (x +. width) (y +. height)) 0xff25201c 0. 0;
    let extent = Plot.draw dl { Plot.series; range; x; y; width; height } in
    text extent;
    Option.iter c.cursor ~f:(fun at ->
      let f = Chart.fraction range at in
      if Float.(f >= 0. && f <= 1.)
      then (
        let cx = x +. (width *. f) in
        B.ImDrawList.add_line dl (v cx y) (v cx (y +. height)) 0xffe0ba72 1. 0));
    Plot_input.handle c ~series ~range ~x ~y ~width ~hovered ~activated;
    Plot_input.record_plot c ~x ~y ~width ~height
  | None -> text "Loading equity..."
;;

let draw_row c page index =
  let row = page.rows.(index) in
  B.table_next_row 0 0.;
  ignore (B.table_set_column_index 0 : bool);
  if
    B.selectable_bool
      (sprintf "%Ld##row-%Ld" row.id.source_row row.id.source_row)
      false
      0
      (v 0. 0.)
    && Option.is_none c.C.page_due
    && Option.is_none c.page_slot.id
  then
    Array.iteri row.cells ~f:(fun index cell ->
      match cell with
      | Time at when String.equal page.fields.(index).name "ts" -> C.set_cursor c at
      | _ -> ());
  Array.iteri c.C.display_rows.(index) ~f:(fun column value ->
    ignore (B.table_set_column_index (column + 1) : bool);
    text value)
;;

let records c =
  choose "Table" c.C.table tables table_name (fun table ->
    c.table <- table;
    c.offset <- 0L;
    C.rows_changed c);
  if button (if c.focus then "Show all times" else "Follow cursor")
  then (
    c.focus <- not c.focus;
    c.offset <- 0L;
    C.rows_changed c);
  toolbar_same ();
  if button "Previous page"
  then (
    c.offset <- Int64.max 0L Int64.(c.offset - 1000L);
    C.rows_changed c);
  toolbar_same ();
  if button "Next page"
  then (
    match c.page with
    | Some page when Array.length page.rows = 1000 ->
      c.offset <- Int64.(c.offset + 1000L);
      C.rows_changed c
    | _ -> ());
  Option.iter c.cursor ~f:(fun at -> paragraph ("Cursor: " ^ Time_ns.to_string_utc at));
  match c.page with
  | None -> text "Loading records..."
  | Some page ->
    paragraph
      ("Displayed records: "
       ^ Option.value_map c.page_cursor ~default:"all times" ~f:Time_ns.to_string_utc);
    text
      (sprintf
         "%s | offset %Ld | %d loaded | %s matching rows"
         (table_name page.table)
         page.offset
         (Array.length page.rows)
         (Option.value_map page.total_rows ~default:"unknown" ~f:Int64.to_string));
    let flags =
      Int64.(
        T.TableFlags.sizing_fixed_fit
        lor T.TableFlags.scroll_y
        lor T.TableFlags.scroll_x
        lor T.TableFlags.row_bg
        lor T.TableFlags.borders
        lor T.TableFlags.resizable)
      |> flag
    in
    if
      B.begin_table
        ("records-" ^ table_name page.table)
        (Array.length page.fields + 1)
        flags
        (v 0. 0.)
        0.
    then (
      B.table_setup_column "Source row" 0 90. 0;
      Array.iter page.fields ~f:(fun field -> B.table_setup_column field.name 0 130. 0);
      B.table_setup_scroll_freeze 1 1;
      B.table_headers_row ();
      let clipper = B.ImGuiListClipper.im_list_clipper () in
      B.ImGuiListClipper.begin_ clipper (Array.length page.rows) (-1.);
      while B.ImGuiListClipper.step clipper do
        let first = !@(clipper |-> T.ListClipper.display_start)
        and last = !@(clipper |-> T.ListClipper.display_end) in
        for index = first to last - 1 do
          draw_row c page index
        done
      done;
      B.ImGuiListClipper.destroy clipper;
      B.end_table ())
;;

type app =
  { mutable controller : C.t option
  ; mutable status : string
  ; mutable picking : bool
  ; mutable picker : Process.t option
  ; mutable opening : bool
  ; mutable closing : bool
  ; mutable path : string
  ; rayforce : string
  ; service_directory : string
  ; backtest_directory : string
  ; mutable strategies : string list
  ; mutable snapshots : string list
  ; mutable strategy : string
  ; mutable snapshot : string
  ; output_buffer : char CArray.t
  ; mutable job : Launcher.t option
  ; mutable opened_job : bool
  ; mutable discovering : bool
  ; mutable discovery_error : string option
  ; mutable show_launcher : bool
  }

let buffer_text buffer =
  let rec length n =
    if n = CArray.length buffer || Char.equal (CArray.get buffer n) '\000'
    then n
    else length (n + 1)
  in
  string_from_ptr (CArray.start buffer) ~length:(length 0)
;;

let open_run app =
  let directory = app.path in
  if String.is_empty (String.strip directory)
  then app.status <- "Choose a saved-run directory, or use Run strategy below."
  else if not app.opening
  then (
    app.opening <- true;
    app.status <- "Verifying bundle and starting result service...";
    let previous = app.controller in
    app.controller <- None;
    let run () =
      (match previous with
       | None -> Deferred.unit
       | Some c -> Session.shutdown c.session)
      >>= fun () ->
      Session.open_bundle
        ~rayforce:app.rayforce
        ~service_directory:app.service_directory
        ~directory
        ~cancelled:(fun () -> app.closing)
      >>= fun result ->
      match result with
      | Error error ->
        app.status <- Error.to_string_hum error;
        Deferred.unit
      | Ok session when app.closing -> Session.shutdown session
      | Ok session ->
        app.controller <- Some (C.create session);
        app.show_launcher <- false;
        app.status <- "Verified saved run | read-only Rayforce service";
        Deferred.unit
    in
    let finish result =
      app.opening <- false;
      match result with
      | Ok () -> ()
      | Error error -> app.status <- Error.to_string_hum error
    in
    don't_wait_for (Monitor.try_with_or_error run >>| finish))
;;

let set_buffer buffer value =
  for i = 0 to CArray.length buffer - 1 do
    CArray.set buffer i '\000'
  done;
  String.iteri
    (String.prefix value (CArray.length buffer - 1))
    ~f:(fun i ch -> CArray.set buffer i ch)
;;

let check_layout = ref false

let check_item_width label right =
  if !check_layout
  then (
    let maximum = getf (B.get_item_rect_max ()) T.Vec2.x in
    if Float.(maximum > right +. 1.)
    then failwith ("Widget exceeds available width: " ^ label))
;;

let input label buffer width =
  let right =
    getf (B.get_cursor_screen_pos ()) T.Vec2.x
    +. getf (B.get_content_region_avail ()) T.Vec2.x
  in
  B.set_next_item_width (if Float.(width < 0.) then width else Float.max 1. width);
  let changed =
    B.input_text
      label
      (CArray.start buffer)
      (CArray.length buffer)
      0
      (fun _ -> 0)
      Ctypes.null
  in
  check_item_width label right;
  changed
;;

let browse app ~initial_directory ~selected =
  if not app.picking
  then (
    app.picking <- true;
    let on_process process =
      app.picker <- Some process;
      if app.closing
      then
        ignore
          (Process.send_signal_compat process Signal.term : [ `Ok | `No_such_process ])
    in
    let finish result =
      app.picking <- false;
      app.picker <- None;
      if not app.closing
      then (
        match result with
        | Ok None -> ()
        | Ok (Some directory) -> selected directory
        | Error error ->
          app.status <- "Cannot select a directory: " ^ Error.to_string_hum error)
    in
    don't_wait_for (Folder_dialog.choose ~initial_directory ~on_process () >>| finish))
;;

let browse_saved app =
  let selected directory =
    app.path <- directory;
    open_run app
  in
  browse
    app
    ~initial_directory:
      (if String.is_empty (String.strip app.path)
       then app.backtest_directory
       else app.path)
    ~selected
;;

let start_strategy app =
  let job =
    Launcher.launch
      ~backtest_directory:app.backtest_directory
      ~service_directory:app.service_directory
      ~rayforce:app.rayforce
      ~strategy:app.strategy
      ~snapshot:app.snapshot
      ~output_parent:(buffer_text app.output_buffer)
  in
  app.job <- Some job;
  app.opened_job <- false
;;

let refresh_sources app =
  if not app.discovering
  then (
    app.discovering <- true;
    app.discovery_error <- None;
    let discover () =
      Launcher.strategies app.backtest_directory
      >>= fun strategies ->
      Launcher.snapshots app.backtest_directory >>| fun snapshots -> strategies, snapshots
    in
    let finish = function
      | Error error ->
        app.discovering <- false;
        app.discovery_error <- Some (Error.to_string_hum error)
      | Ok (strategies, snapshots) ->
        app.discovering <- false;
        app.strategies <- strategies;
        app.snapshots <- snapshots;
        if not (List.mem strategies app.strategy ~equal:String.equal)
        then
          app.strategy
          <- (if List.mem strategies "trend" ~equal:String.equal
              then "trend"
              else Option.value (List.hd strategies) ~default:"");
        if not (List.mem snapshots app.snapshot ~equal:String.equal)
        then
          app.snapshot
          <- Option.value
               (List.find snapshots ~f:(fun path ->
                  String.is_prefix (Filename.basename path) ~prefix:"binance-spot-1d-"))
               ~default:(Option.value (List.hd snapshots) ~default:"")
    in
    don't_wait_for (Monitor.try_with_or_error discover >>| finish))
;;

let labeled_choice label current choices name select =
  text label;
  let right =
    getf (B.get_cursor_screen_pos ()) T.Vec2.x
    +. getf (B.get_content_region_avail ()) T.Vec2.x
  in
  B.set_next_item_width (-1.);
  choose ("##" ^ label) current choices name select;
  check_item_width label right
;;

let launch_controls app =
  B.separator_text "Run strategy";
  paragraph "Run a strategy and its buy-and-hold baseline on a verified snapshot.";
  paragraph
    "Uses the configuration and strategy parameters in run.rfl and strategies/*.rfl.";
  let busy = Option.exists app.job ~f:Launcher.active in
  B.begin_disabled busy;
  labeled_choice "Strategy" app.strategy app.strategies Fn.id (fun value ->
    app.strategy <- value);
  labeled_choice "Snapshot" app.snapshot app.snapshots Filename.basename (fun value ->
    app.snapshot <- value);
  text "Output folder";
  ignore (input "##output-folder" app.output_buffer (-1.) : bool);
  B.begin_disabled app.picking;
  if button "Browse output folder..."
  then
    browse
      app
      ~initial_directory:(buffer_text app.output_buffer)
      ~selected:(set_buffer app.output_buffer);
  B.end_disabled ();
  B.end_disabled ();
  B.begin_disabled
    (busy
     || app.discovering
     || String.is_empty app.strategy
     || String.is_empty app.snapshot);
  if button "Run strategy" then start_strategy app;
  B.end_disabled ();
  if app.discovering
  then paragraph "Finding strategies and local snapshots..."
  else (
    B.begin_disabled busy;
    if button "Refresh strategies and snapshots" then refresh_sources app;
    B.end_disabled ();
    Option.iter app.discovery_error ~f:(fun error ->
      paragraph ("Discovery failed: " ^ error));
    if List.is_empty app.snapshots && Option.is_none app.discovery_error
    then
      paragraph
        ("No local snapshots found in "
         ^ Filename.concat app.backtest_directory "data"
         ^ ". Run make data in the backtester directory to download them."));
  paragraph ("Backtester: " ^ app.backtest_directory);
  Option.iter app.job ~f:(fun job ->
    (match job.phase with
     | Launcher.Running ->
       text "Running...";
       same ();
       if button "Cancel" then Launcher.cancel job
     | Publishing ->
       text "Validating and publishing...";
       same ();
       if button "Cancel" then Launcher.cancel job
     | Completed _ ->
       text "Completed";
       if button "Inspect result"
       then (
         app.path <- job.directory;
         open_run app)
     | Cancelled -> text "Cancelled"
     | Failed message -> text message);
    paragraph ("Result: " ^ job.directory);
    B.separator_text "Run log";
    List.iter (List.rev job.logs) ~f:paragraph)
;;

let refresh_job app =
  match app.job with
  | Some { phase = Launcher.Completed _; directory; _ } when not app.opened_job ->
    app.opened_job <- true;
    app.show_launcher <- false;
    app.path <- directory;
    open_run app
  | _ -> ()
;;

let inspection_tabs c =
  if B.begin_tab_bar "Inspection" 0
  then (
    let tab title draw =
      if
        B.begin_tab_item
          title
          (Platform.null bool)
          (if
             !Plot_input.testing
             && (not (Plot_input.finished ()))
             && String.equal title "Equity"
           then flag T.TabItemFlags.set_selected
           else 0)
      then (
        child (title ^ " contents") 0. 0. draw;
        B.end_tab_item ())
    in
    tab "Summary" (fun () -> provenance c);
    tab "Equity" (fun () -> chart c);
    tab "Records" (fun () -> records c);
    B.end_tab_bar ())
;;

let inspection c =
  let available = B.get_content_region_avail () in
  let width = getf available T.Vec2.x
  and height = getf available T.Vec2.y in
  if Float.(width < 1050. || height < 450.)
  then inspection_tabs c
  else (
    child "Run and summary" (width *. 0.32) 0. (fun () -> provenance c);
    same ();
    let right () =
      let height = getf (B.get_content_region_avail ()) T.Vec2.y in
      child "Equity" 0. (height *. 0.45) (fun () -> chart c);
      child "Records" 0. 0. (fun () -> records c)
    in
    child "Details" 0. 0. right)
;;

let browse_icon () =
  let size = B.get_frame_height () in
  let clicked = B.button "##browse-saved-run" (v (size +. 4.) size) in
  let minimum = B.get_item_rect_min ()
  and maximum = B.get_item_rect_max () in
  let x = getf minimum T.Vec2.x
  and y = getf minimum T.Vec2.y in
  let width = getf maximum T.Vec2.x -. x in
  let point (px, py) = v (x +. (px *. width)) (y +. (py *. size)) in
  let points =
    CArray.of_list
      T.Vec2.t
      (List.map
         [ 0.18, 0.27; 0.43, 0.27; 0.52, 0.4; 0.82, 0.4; 0.82, 0.8; 0.18, 0.8 ]
         ~f:point)
  in
  B.ImDrawList.add_polyline
    (B.get_window_draw_list ())
    (CArray.start points)
    (CArray.length points)
    (B.get_color_u32_col (flag T.Col.text) 1.)
    1.5
    (flag T.DrawFlags.closed);
  if B.is_item_hovered 0 && B.begin_tooltip ()
  then (
    text "Open saved run";
    B.end_tooltip ());
  clicked
;;

let shutdown_tab app =
  app.closing <- true;
  Option.iter app.picker ~f:(fun process ->
    ignore (Process.send_signal_compat process Signal.term : [ `Ok | `No_such_process ]));
  let rec stop () =
    if app.opening || app.picking
    then Clock_ns.after (Time_ns.Span.of_int_ms 10) >>= stop
    else (
      match app.controller with
      | None -> Deferred.unit
      | Some c -> Session.shutdown c.session)
  in
  (match app.job with
   | None -> Deferred.unit
   | Some job -> Launcher.shutdown job)
  >>= stop
;;

type tab =
  { id : int
  ; app : app
  }

type workspace =
  { mutable tabs : tab list
  ; mutable next_id : int
  ; mutable selected : int
  ; mutable focus : int option
  ; mutable retiring : unit Deferred.t list
  ; mutable closing : bool
  ; create : string -> app
  }

let add_tab workspace directory =
  let app = workspace.create directory in
  let tab = { id = workspace.next_id; app } in
  workspace.next_id <- workspace.next_id + 1;
  workspace.tabs <- workspace.tabs @ [ tab ];
  workspace.selected <- tab.id;
  workspace.focus <- Some tab.id;
  tab
;;

let close_tab workspace tab =
  workspace.tabs <- List.filter workspace.tabs ~f:(fun t -> t.id <> tab.id);
  workspace.retiring <- shutdown_tab tab.app :: workspace.retiring;
  if workspace.selected = tab.id
  then Option.iter (List.hd workspace.tabs) ~f:(fun tab -> workspace.selected <- tab.id)
;;

let tab_title tab =
  let name =
    match tab.app.controller with
    | Some c -> c.C.strategy
    | None ->
      (match tab.app.job with
       | Some _ -> tab.app.strategy
       | None -> "New backtest")
  in
  sprintf "%s #%d###backtest-%d" name (tab.id + 1) tab.id
;;

let draw_tab workspace tab =
  let open_ = allocate bool true in
  let flags =
    if Option.equal Int.equal workspace.focus (Some tab.id)
    then flag T.TabItemFlags.set_selected
    else 0
  in
  let visible = B.begin_tab_item (tab_title tab) open_ flags in
  if visible
  then (
    workspace.selected <- tab.id;
    if Option.equal Int.equal workspace.focus (Some tab.id) then workspace.focus <- None;
    B.push_id_int tab.id;
    paragraph tab.app.status;
    if tab.app.show_launcher || Option.is_none tab.app.controller
    then child "Launcher" 0. 0. (fun () -> launch_controls tab.app)
    else Option.iter tab.app.controller ~f:inspection;
    B.pop_id ();
    B.end_tab_item ());
  if not !@open_ then close_tab workspace tab
;;

let draw workspace =
  workspace.retiring
  <- List.filter workspace.retiring ~f:(fun stopped ->
       not (Deferred.is_determined stopped));
  List.iter workspace.tabs ~f:(fun tab ->
    refresh_job tab.app;
    Option.iter tab.app.controller ~f:(fun c ->
      C.tick c;
      Option.iter c.error ~f:(fun error -> tab.app.status <- error)));
  let display = !@(B.get_io_nil () |-> T.Io.display_size) in
  B.set_next_window_pos (v 0. 0.) (flag T.Cond.always) (v 0. 0.);
  B.set_next_window_size display (flag T.Cond.always);
  let flags =
    Int64.(
      T.WindowFlags.no_title_bar
      lor T.WindowFlags.no_resize
      lor T.WindowFlags.no_move
      lor T.WindowFlags.no_collapse
      lor T.WindowFlags.no_saved_settings)
    |> flag
  in
  let visible = B.begin_ "Workbench" (Platform.null bool) flags in
  if visible
  then (
    let selected = List.find workspace.tabs ~f:(fun tab -> tab.id = workspace.selected) in
    B.begin_disabled (Option.exists selected ~f:(fun tab -> tab.app.picking));
    if browse_icon ()
    then (
      let owner =
        match selected with
        | Some tab -> tab
        | None -> add_tab workspace ""
      in
      let chosen directory =
        let reuse =
          Option.is_none owner.app.controller
          && Option.is_none owner.app.job
          && not owner.app.opening
        in
        let tab = if reuse then owner else add_tab workspace "" in
        workspace.selected <- tab.id;
        workspace.focus <- Some tab.id;
        tab.app.path <- directory;
        open_run tab.app
      in
      browse owner.app ~initial_directory:owner.app.backtest_directory ~selected:chosen);
    B.end_disabled ();
    same ();
    if button "New backtest" then ignore (add_tab workspace "" : tab);
    if B.begin_tab_bar "Backtests" (flag T.TabBarFlags.reorderable)
    then (
      List.iter workspace.tabs ~f:(draw_tab workspace);
      B.end_tab_bar ()));
  B.end_ ()
;;

let controller_ready c =
  Option.is_some c.C.series
  && Option.is_some c.page
  && Option.is_some c.summary
  && Option.is_none c.page_due
  && Option.is_none c.page_slot.id
;;

let tabs_test_stage = ref 0
let tabs_test_second = ref None
let tabs_test_session = ref None
let tabs_test_cancelled = ref None

let exercise_tabs workspace app =
  let settled () = List.for_all workspace.retiring ~f:Deferred.is_determined in
  match !tabs_test_stage with
  | 0 ->
    let tab = add_tab workspace "" in
    tab.app.path <- app.path;
    open_run tab.app;
    tabs_test_second := Some tab;
    tabs_test_stage := 1
  | 1 ->
    let tab = Option.value_exn !tabs_test_second in
    Option.iter tab.app.controller ~f:(fun second ->
      if controller_ready second
      then (
        if tab.app.show_launcher
        then failwith "Opening a saved run left its launcher visible";
        let first = Option.value_exn app.controller in
        if phys_equal first.session second.session
        then failwith "Tabs share a service session";
        let cursor = first.cursor
        and range = first.range
        and table = first.table in
        Option.iter second.series ~f:(fun series ->
          if Array.length series.points > 1 then C.set_cursor second series.points.(1).at);
        if
          not
            (Option.equal Time_ns.equal first.cursor cursor
             && phys_equal first.range range
             && Poly.equal first.table table)
        then failwith "Changing another tab modified the first tab";
        tabs_test_session := Some second.session;
        close_tab workspace tab;
        workspace.focus <- Some 0;
        tabs_test_stage := 2))
  | 2 when settled () ->
    let session = Option.value_exn !tabs_test_session in
    if
      not
        (Deferred.is_determined session.exited
         && Backtest_reader.Reader.is_closed session.reader)
    then failwith "Closing a tab did not stop its service";
    if Deferred.is_determined (Option.value_exn app.controller).session.exited
    then failwith "Closing a tab stopped another service";
    let pending = add_tab workspace "" in
    pending.app.strategy <- app.strategy;
    pending.app.snapshot <- app.snapshot;
    set_buffer pending.app.output_buffer (Filename.dirname app.path);
    start_strategy pending.app;
    tabs_test_cancelled := pending.app.job;
    close_tab workspace pending;
    workspace.focus <- Some 0;
    tabs_test_stage := 3
  | 3 when settled () ->
    (match (Option.value_exn !tabs_test_cancelled).phase with
     | Launcher.Cancelled -> ()
     | _ -> failwith "Closing a running tab did not cancel its job");
    tabs_test_stage := 4;
    printf "Tabs: isolated selection, service shutdown and launch cancellation passed\n%!"
  | _ -> ()
;;

let run
      directory
      service_directory
      backtest_directory
      rayforce
      font
      output_parent
      smoke
      smoke_launch
      smoke_layout
      smoke_close
      screenshot
  =
  Typography.resolve font
  >>= fun font ->
  check_layout := smoke;
  Plot_input.testing := smoke && not smoke_layout;
  let w = Platform.open_window () in
  ignore (B.create_context (Platform.null T.FontAtlas.t) : T.Context.t ptr);
  B.style_colors_dark (Platform.null T.Style.t);
  Typography.install font;
  (* ImGui must never retain an OCaml temporary string or write imgui.ini. *)
  let ini = from_voidp (ptr char) (to_voidp (B.get_io_nil () |-> T.Io.ini_filename)) in
  ini <-@ Platform.null char;
  if not (Imguiml_impl.Glfw.init_for_opengl w true)
  then failwith "ImGui GLFW initialization failed";
  if not (Imguiml_impl.OpenGL3.init (Some "#version 330"))
  then failwith "ImGui OpenGL initialization failed";
  let create directory =
    let app =
      { controller = None
      ; status = "Choose a saved native run"
      ; picking = false
      ; picker = None
      ; opening = false
      ; closing = false
      ; path = directory
      ; rayforce
      ; service_directory
      ; backtest_directory
      ; strategies = []
      ; snapshots = []
      ; strategy = ""
      ; snapshot = ""
      ; output_buffer = CArray.make char 4096
      ; job = None
      ; opened_job = false
      ; discovering = false
      ; discovery_error = None
      ; show_launcher = String.is_empty directory
      }
    in
    set_buffer
      app.output_buffer
      (Option.value
         output_parent
         ~default:(Filename.concat backtest_directory "out/workbench"));
    refresh_sources app;
    if not (String.is_empty directory) then open_run app;
    app
  in
  let app = create directory in
  let workspace =
    { tabs = [ { id = 0; app } ]
    ; next_id = 1
    ; selected = 0
    ; focus = None
    ; retiring = []
    ; closing = false
    ; create
    }
  in
  if smoke_layout
  then (
    app.path <- "   ";
    open_run app;
    if app.opening then failwith "Blank Open left the viewer busy";
    app.path <- directory;
    app.status <- "Choose a saved native run");
  if smoke_close
  then (
    browse_saved app;
    don't_wait_for
      (Clock_ns.after (Time_ns.Span.of_int_ms 100)
       >>| fun () -> Platform.request_close w true));
  Platform.current (Platform.null Platform.window);
  let started = Time_ns.now () in
  let smoke_stage = ref 0
  and ready_frames = ref 0 in
  let rec frame () =
    if Platform.should_close w || workspace.closing
    then Deferred.unit
    else (
      Platform.current w;
      Platform.poll ();
      Imguiml_impl.OpenGL3.new_frame ();
      Imguiml_impl.Glfw.new_frame ();
      if !Plot_input.testing then Plot_input.inject_events ();
      B.new_frame ();
      B.push_font (Platform.null T.Font.t) 18.;
      if
        smoke_launch
        && Option.is_none app.job
        && (not (String.is_empty app.strategy))
        && not (String.is_empty app.snapshot)
      then start_strategy app;
      draw workspace;
      B.pop_font ();
      B.render ();
      let width, height = Platform.size w in
      Platform.viewport 0 0 width height;
      Platform.clear_color 0.06 0.075 0.09 1.;
      Platform.clear 0x4000;
      Imguiml_impl.OpenGL3.render_draw_data (B.get_draw_data ());
      if
        smoke_layout
        && (not app.discovering)
        && (List.is_empty app.strategies || List.is_empty app.snapshots)
      then
        failwith
          ("Layout test requires discovered strategies and snapshots: "
           ^ Option.value app.discovery_error ~default:app.backtest_directory);
      let ready =
        (smoke_layout && not app.discovering)
        || Option.exists app.controller ~f:controller_ready
      in
      let ready = ready && ((not !Plot_input.testing) || Plot_input.finished ()) in
      if smoke && (not smoke_layout) && ready && !tabs_test_stage < 4
      then exercise_tabs workspace app;
      let ready = ready && (smoke_layout || !tabs_test_stage >= 4) in
      if smoke && ready
      then (
        Texture_check.check ();
        incr ready_frames);
      if smoke && !ready_frames = 3 then Platform.set_size w 360 420;
      if smoke && !ready_frames = 7 then Platform.set_size w 540 500;
      if smoke && !ready_frames = 11 then Platform.set_size w 420 600;
      let finish = smoke && !ready_frames >= 17 in
      let image =
        if finish then Option.map screenshot ~f:(fun _ -> Platform.screenshot w) else None
      in
      Platform.swap w;
      Platform.current (Platform.null Platform.window);
      (if finish
       then (
         printf "GUI smoke: data, resize sequence and widget bounds passed\n%!";
         Platform.request_close w true;
         match screenshot, image with
         | Some file, Some contents -> Writer.save file ~contents
         | _ -> Deferred.unit)
       else if
         smoke && Time_ns.Span.(Time_ns.diff (Time_ns.now ()) started > of_int_sec 20)
       then failwith ("GUI smoke timed out: " ^ app.status)
       else (
         if smoke && ready && !smoke_stage = 0
         then (
           smoke_stage := 1;
           Option.iter app.controller ~f:(fun c ->
             Option.iter c.series ~f:(fun series ->
               if Array.length series.points > 1 then C.set_cursor c series.points.(1).at)));
         Clock_ns.after (Time_ns.Span.of_int_ms 16)))
      >>= frame)
  in
  let cleanup () =
    app.closing <- true;
    (* Reacquire the context before releasing native graphics resources. *)
    Platform.current w;
    Imguiml_impl.OpenGL3.shutdown ();
    Imguiml_impl.Glfw.shutdown ();
    B.destroy_context (Platform.null T.Context.t);
    Platform.destroy w;
    Platform.terminate ();
    workspace.closing <- true;
    Deferred.all_unit
      (List.map workspace.tabs ~f:(fun tab -> shutdown_tab tab.app) @ workspace.retiring)
  in
  Signal.handle [ Signal.int; Signal.term ] ~f:(fun _ -> workspace.closing <- true)
  |> Fn.ignore;
  Monitor.protect frame ~finally:cleanup
;;

let () =
  Command.async
    ~summary:"Native saved-run backtest viewer"
    (let%map_open.Command directory =
       flag "-run" (optional_with_default "" string) ~doc:"DIR verified saved run"
     and service =
       flag "-service-directory" (required string) ~doc:"DIR Rayfall read-service sources"
     and backtest_directory =
       flag "-backtest-directory" (required string) ~doc:"DIR backtester sources and data"
     and output_parent =
       flag "-output-parent" (optional string) ~doc:"DIR default parent for launched runs"
     and smoke_close =
       flag "-smoke-close" no_arg ~doc:" test native close with a folder chooser active"
     and smoke_layout =
       flag
         "-smoke-layout"
         no_arg
         ~doc:" check launcher discovery and narrow-window widget bounds"
     and smoke_launch =
       flag
         "-smoke-launch"
         no_arg
         ~doc:" launch the selected strategy as part of a smoke test"
     and font =
       flag "-font" (optional string) ~doc:"FILE TrueType font (defaults to system sans)"
     and rayforce =
       flag
         "-rayforce"
         (optional_with_default "rayforce" string)
         ~doc:"PATH engine executable"
     and smoke = flag "-smoke-test" no_arg ~doc:" render real data then exit"
     and screenshot =
       flag "-screenshot" (optional string) ~doc:"FILE PPM image from smoke test"
     in
     fun () ->
       run
         directory
         service
         backtest_directory
         rayforce
         font
         output_parent
         (smoke || smoke_launch || smoke_layout)
         smoke_launch
         smoke_layout
         smoke_close
         screenshot)
  |> Command_unix.run
;;
