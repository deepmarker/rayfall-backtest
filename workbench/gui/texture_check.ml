open Core
open Ctypes
module B = Imguiml.Bindings
module T = Imguiml.Types

let get_integer =
  Foreign.foreign ~from:Platform.gl "glGetIntegerv" (int @-> ptr int @-> returning void)
;;

let bind =
  Foreign.foreign ~from:Platform.gl "glBindTexture" (int @-> int @-> returning void)
;;

let read =
  Foreign.foreign
    ~from:Platform.gl
    "glGetTexImage"
    (int @-> int @-> int @-> int @-> ptr void @-> returning void)
;;

let level =
  Foreign.foreign
    ~from:Platform.gl
    "glGetTexLevelParameteriv"
    (int @-> int @-> int @-> ptr int @-> returning void)
;;

let gl_error = Foreign.foreign ~from:Platform.gl "glGetError" (void @-> returning int)

let check () =
  let atlas = !@(B.get_io_nil () |-> T.Io.fonts) in
  let texture = !@(atlas |-> T.FontAtlas.tex_data) in
  if
    (not (is_null texture))
    &&
    match !@(texture |-> T.TextureData.status) with
    | T.TextureStatus.OK -> true
    | _ -> false
  then (
    let width = !@(texture |-> T.TextureData.width)
    and height = !@(texture |-> T.TextureData.height) in
    let size = width * height * 4 in
    let pixels = !@(texture |-> T.TextureData.pixels) in
    let saved = allocate int 0 in
    get_integer 0x8069 saved;
    bind 0x0DE1 !@(texture |-> T.TextureData.tex_id);
    let actual_width = allocate int 0
    and actual_height = allocate int 0 in
    level 0x0DE1 0 0x1000 actual_width;
    level 0x0DE1 0 0x1001 actual_height;
    if !@actual_width <> width || !@actual_height <> height
    then
      failwith
        (sprintf
           "Atlas size CPU %dx%d GPU %dx%d"
           width
           height
           !@actual_width
           !@actual_height);
    let output = CArray.make char size in
    let previous_error = gl_error () in
    read 0x0DE1 0 0x1908 0x1401 (to_voidp (CArray.start output));
    let read_error = gl_error () in
    if previous_error <> 0 || read_error <> 0
    then failwith (sprintf "Font atlas GL errors: %x %x" previous_error read_error);
    bind 0x0DE1 !@saved;
    let mismatch = ref 0 in
    for i = 0 to size - 1 do
      if Char.to_int (CArray.get output i) <> !@(pixels +@ i) then incr mismatch
    done;
    if !mismatch <> 0
    then failwith (sprintf "Font atlas GPU mismatch: %d bytes of %d" !mismatch size))
;;
