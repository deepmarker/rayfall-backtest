open Core
open Async
open Ctypes
module B = Imguiml.Bindings
module T = Imguiml.Types

let resolve font =
  match font with
  | Some font -> return (Some font)
  | None ->
    Process.run ~prog:"fc-match" ~args:[ "-f"; "%{file}"; "sans" ] ()
    >>| (function
     | Ok path when not (String.is_empty (String.strip path)) -> Some (String.strip path)
     | _ -> None)
;;

let install path =
  let io = B.get_io_nil () in
  let atlas = !@(io |-> T.Io.fonts) in
  let font =
    match path with
    | Some path ->
      B.ImFontAtlas.add_font_from_file_ttf
        atlas
        path
        18.
        (Platform.null T.FontConfig.t)
        (Platform.null T.wchar_t)
    | None -> B.ImFontAtlas.add_font_default_vector atlas (Platform.null T.FontConfig.t)
  in
  if is_null font then failwith "Cannot load GUI font";
  io |-> T.Io.font_default <-@ font;
  io |-> T.Io.config_dpi_scale_fonts <-@ true
;;
