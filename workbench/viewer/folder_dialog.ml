open Core
open Async

let choose ?(prog = "zenity") ~initial_directory ~on_process () =
  let run () =
    let args = [ "--file-selection"; "--directory"; "--title=Choose a directory" ] in
    let args =
      if String.is_empty initial_directory
      then args
      else args @ [ "--filename=" ^ Filename.concat initial_directory "" ]
    in
    Process.create ~prog ~args ()
    >>= fun created ->
    let process = Or_error.ok_exn created in
    on_process process;
    Process.collect_output_and_wait process
    >>= fun output ->
    match output.exit_status with
    | Error (`Exit_non_zero 1) -> return None
    | Error _ -> failwith ("Directory chooser failed: " ^ String.strip output.stderr)
    | Ok () ->
      let directory =
        Option.value
          (String.chop_suffix output.stdout ~suffix:"\n")
          ~default:output.stdout
      in
      if String.is_empty directory then failwith "Directory chooser returned no directory";
      Unix.stat directory
      >>| fun stat ->
      if not (Unix.File_kind.equal stat.kind `Directory)
      then failwith "Choose a directory, rather than a file";
      Some directory
  in
  Monitor.try_with_or_error run
;;
