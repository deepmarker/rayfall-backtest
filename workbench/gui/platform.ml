open Core
open Ctypes

let glfw = Dl.dlopen ~filename:"libglfw.so.3" ~flags:[ Dl.RTLD_NOW; Dl.RTLD_GLOBAL ]
let gl = Dl.dlopen ~filename:"libGL.so.1" ~flags:[ Dl.RTLD_NOW; Dl.RTLD_GLOBAL ]
let foreign name signature = Foreign.foreign ~from:glfw name signature
let init = foreign "glfwInit" (void @-> returning int)
let terminate = foreign "glfwTerminate" (void @-> returning void)
let hint = foreign "glfwWindowHint" (int @-> int @-> returning void)
let window = Imguiml_impl.Glfw.window

let create =
  foreign
    "glfwCreateWindow"
    (int @-> int @-> string @-> ptr void @-> ptr window @-> returning (ptr window))
;;

let destroy = foreign "glfwDestroyWindow" (ptr window @-> returning void)
let current_window = foreign "glfwGetCurrentContext" (void @-> returning (ptr window))
let current = foreign "glfwMakeContextCurrent" (ptr window @-> returning void)
let swap_interval = foreign "glfwSwapInterval" (int @-> returning void)
let swap = foreign "glfwSwapBuffers" (ptr window @-> returning void)
let poll = foreign "glfwPollEvents" (void @-> returning void)
let set_size = foreign "glfwSetWindowSize" (ptr window @-> int @-> int @-> returning void)

let request_close =
  foreign "glfwSetWindowShouldClose" (ptr window @-> bool @-> returning void)
;;

let should_close = foreign "glfwWindowShouldClose" (ptr window @-> returning bool)

let framebuffer =
  foreign "glfwGetFramebufferSize" (ptr window @-> ptr int @-> ptr int @-> returning void)
;;

let viewport =
  Foreign.foreign ~from:gl "glViewport" (int @-> int @-> int @-> int @-> returning void)
;;

let clear_color =
  Foreign.foreign
    ~from:gl
    "glClearColor"
    (float @-> float @-> float @-> float @-> returning void)
;;

let clear = Foreign.foreign ~from:gl "glClear" (int @-> returning void)
let pixel_store = Foreign.foreign ~from:gl "glPixelStorei" (int @-> int @-> returning void)

let read_pixels =
  Foreign.foreign
    ~from:gl
    "glReadPixels"
    (int @-> int @-> int @-> int @-> int @-> int @-> ptr void @-> returning void)
;;

let null typ = from_voidp typ Ctypes.null

let size w =
  let x = allocate int 0
  and y = allocate int 0 in
  framebuffer w x y;
  !@x, !@y
;;

let open_window () =
  if init () = 0 then failwith "GLFW initialization failed (is a display available?)";
  hint 0x00022002 3;
  hint 0x00022003 3;
  hint 0x00022008 0x00032001;
  let w = create 1440 1000 "Rayfall backtest workbench" Ctypes.null (null window) in
  if is_null w
  then (
    terminate ();
    failwith "Cannot create OpenGL window");
  current w;
  swap_interval 0;
  w
;;

let screenshot w =
  let width, height = size w in
  let data = CArray.make char (width * height * 3) in
  pixel_store 0x0D05 1;
  read_pixels 0 0 width height 0x1907 0x1401 (to_voidp (CArray.start data));
  let bytes = Bytes.create (width * height * 3) in
  for y = 0 to height - 1 do
    for x = 0 to (width * 3) - 1 do
      Bytes.set
        bytes
        ((y * width * 3) + x)
        (CArray.get data (((height - y - 1) * width * 3) + x))
    done
  done;
  sprintf "P6\n%d %d\n255\n" width height ^ Bytes.to_string bytes
;;
