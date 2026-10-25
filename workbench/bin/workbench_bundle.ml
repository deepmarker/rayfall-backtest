open Core
open Async
module Bundle = Backtest_bundle.Bundle

let verify =
  Command.async_or_error
    ~summary:"Verify a published native run bundle"
    (let%map_open.Command directory =
       flag "directory" (required string) ~doc:"DIR saved run"
     in
     fun () ->
       Bundle.verify ~directory >>|? fun info -> printf "Verified run %s\n" info.id)
;;

let publish =
  Command.async_or_error
    ~summary:"Export, validate and atomically publish a native run"
    (let%map_open.Command directory =
       flag "directory" (required string) ~doc:"DIR new saved run"
     and rayforce =
       flag
         "rayforce"
         (optional_with_default "rayforce" string)
         ~doc:"EXE Rayforce binary"
     and service_directory =
       flag "service-directory" (required string) ~doc:"DIR workbench Rayfall sources"
     and producer = flag "producer" (required string) ~doc:"FILE Rayfall exporter script"
     and working_dir =
       flag "producer-cwd" (optional string) ~doc:"DIR producer working directory"
     and args =
       flag
         "producer-arg"
         (listed string)
         ~doc:"ARG extra producer argument; repeat per token"
     in
     fun () ->
       Unix.getcwd ()
       >>= fun cwd ->
       let absolute path =
         if Filename.is_relative path then Filename.concat cwd path else path
       in
       let directory = absolute directory in
       let service_directory = absolute service_directory in
       let producer = absolute producer in
       let write ~directory =
         let args =
           [ "-c"
           ; "1"
           ; "-f"
           ; producer
           ; "--"
           ; "-directory"
           ; directory
           ; "-service"
           ; Filename.concat service_directory "service.rfl"
           ; "-bundle_module"
           ; Filename.concat service_directory "bundle.rfl"
           ]
           @ args
         in
         Process.run ?working_dir ~prog:rayforce ~args () >>| Or_error.map ~f:ignore
       in
       Bundle.publish ~directory ~rayforce ~service_directory ~write
       >>|? fun info -> printf "Published run %s\n" info.id)
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"Native backtest run bundles"
       [ "verify", verify; "publish", publish ])
;;
