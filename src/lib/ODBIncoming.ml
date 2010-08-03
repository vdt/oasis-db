
(*open Sexplib.Conv*)
open ODBMessage
open ODBGettext
open ODBTypes
open ODBInotify
open ODBCompletion
open ODBVer
open Sexplib.Sexp
open Sexplib.Conv
open Lwt

TYPE_CONV_PATH "ODBIncoming"

type upload_t =
  {
    publink:       url sexp_option;
    upload_method: upload_method;
  } with sexp 

type t =
  | Step1_JustUploaded of upload_t
  (** Use just uploaded the package *)
  | Step2_UserEditable of upload_t * ODBCompletion.t
  (** We run parameter completion but either we are not sure
      about values or there are errors or the upload method 
      implies a user validation.
   *)
  | Step3_UserValidated of upload_t * name * version * int * filename option
  (** The user has reviewed the parameter, we can proceed.
   *)
  with sexp

type vt = 
  V1 of t with sexp

let upgrade ~ctxt =
  function
    | V1 t -> return t

(** Load from file *)
let from_file = 
  LwtExt.IO.sexp_load vt_of_sexp upgrade

(** Dump to file *)
let to_file =
  LwtExt.IO.sexp_dump sexp_of_vt (fun t -> V1 t)

(** We got all files and all parameters are set, so move tarball to storage
  *)
let move_to_storage ~ctxt ut pkg ver ord tarball_fn sexp_fn oasis_fn =
  let upload_date =
    CalendarLib.Calendar.from_unixfloat
      (Unix.stat tarball_fn).Unix.st_mtime
  in
  let ver = 
    {
      ODBVer.pkg    = pkg;
      ver           = ver;
      ord           = ord;
      tarball       = Filename.basename tarball_fn;
      upload_date   = upload_date;
      upload_method = ut.upload_method;
      publink       = ut.publink;
    }
  in
    (* TODO: catch errors and avoid deletion *)
    ODBStorage.add_version ~ctxt ver tarball_fn oasis_fn
    >>= fun () ->
    ODBFileUtil.rm ~ctxt [tarball_fn; sexp_fn]

(** We got all files, try to run completion on them
  *)
let upload_complete ~ctxt sexp_fn tarball_fn = 
  from_file ~ctxt sexp_fn
  >>= function
    | Step1_JustUploaded ut ->
        begin
          debug ~ctxt
            (f_ "Run completion on tarball '%s'")
            tarball_fn
          >>= fun () ->
          ODBArchive.uncompress_tmp_dir ~ctxt tarball_fn 
          (fun fn an dn ->
            ODBCompletion.run ~ctxt fn an dn 
            >>= fun ct ->
            (* Conditions to go to step 2 or directly 
             * to storage
             *)
            let upload_method_need_ack = 
              match ut.upload_method with
              | Manual _ -> true
              | OCamlForge | Uscan | API _ -> false
            in

              match ct with 
              (* Completion is sure *)
              | {ODBCompletion.pkg = Sure pkg; 
                 ver = Sure ver; ord = Sure ord;
                 oasis_fn = oasis_fn} 
                 when not upload_method_need_ack ->
                  debug ~ctxt 
                    (f_ "Everything is complete, move tarball to storege")
                  >>= fun () -> 
                  (* We have everything we need -> move to storage *)
                  move_to_storage ~ctxt ut pkg ver ord 
                    tarball_fn sexp_fn oasis_fn

              | _ ->
                  (* We need some inputs from user -> go to step 2 *)
                  to_file ~ctxt sexp_fn (Step2_UserEditable (ut, ct)))
        end

    | Step2_UserEditable _ ->
        debug ~ctxt 
          (f_ "Wait for user input")

    | Step3_UserValidated (ut, pkg, ver, ord, oasis_fn) ->
        debug ~ctxt
          (f_ "Moving tarball to storage")
        >>= fun () ->
        move_to_storage ~ctxt ut pkg ver ord
          tarball_fn sexp_fn oasis_fn

module SetString = Set.Make(String)

(** Wait to have tarball + sexp files
  *)
let wait_complete ~ctxt ev changed = 
  match ev with 
  | Created fn ->
      begin
        return changed
      end
  
  | Changed fn ->
      begin
        let changed = SetString.add fn changed in

        let sexp_fn, tarball_fn  = 
          if Filename.check_suffix fn ".sexp" then
            fn, Filename.chop_extension fn
          else
            fn^".sexp", fn
        in

        (* Check that we have received Changed event for 
         * both tarball and sexp 
         *)
        if SetString.mem sexp_fn changed && 
           Sys.file_exists sexp_fn &&
           SetString.mem tarball_fn changed && 
           Sys.file_exists tarball_fn then
          (* We have a winner, the upload seems complete *)
          let ctxt = 
            ODBContext.sub ctxt (Filename.basename tarball_fn)
          in
          debug 
            ~ctxt
            (f_ "Upload complete for file '%s'")
            tarball_fn
          >>= fun () ->
          upload_complete ~ctxt sexp_fn tarball_fn 
          >>= fun () ->
          return changed

        else
          return changed

          (*
      else if sexp_exists then
        debug ~ctxt
          (f_ "Missing file '%s'") sexp_fn
      else if tarball_exists then
        debug ~ctxt
          (f_ "Missing file '%s'") tarball_fn
      else
        debug ~ctxt
          (f_ "Missing file '%s' and '%s'")
          sexp_fn tarball_fn
          *)
      end

  | Deleted fn ->
      begin
        return (SetString.remove fn changed)
      end

(** Main loop for incoming/ watch
  *)
let run = 
  ODBRunner.singleton 
    "ODBIncoming.run"
    (fun ~ctxt () ->
      let ctxt = ODBContext.sub ctxt "incoming" in

      ODBInotify.monitor_dir ~ctxt 
        (wait_complete ~ctxt)
        ODBConf.incoming_dir SetString.empty
      >>= fun changed ->
      if SetString.cardinal changed > 0 then
        info ~ctxt
          (f_ "Remaining files in the incoming directory: %s")
            (String.concat (s_ ", ")
              (List.rev_map 
                (fun fn -> 
                  Printf.sprintf
                    (if Sys.file_exists fn then
                      format_of_string "%s"
                    else
                      "%s?")
                    (Filename.basename fn))
                (SetString.elements changed)))
        else
          return ())

let make ?publink upload_method = 
  Step1_JustUploaded {publink = publink; upload_method = upload_method}

let sexp_of_tarball tarball = 
  FilePath.concat
    ODBConf.incoming_dir
    (tarball ^ ".sexp")

(** Upload a tarball -> step 1
  *)
let upload ~ctxt ~tarball_fn mthd tarball = 
  let tarball_tgt =
    FilePath.concat ODBConf.incoming_dir tarball
  in

    ODBFileUtil.cp ~ctxt [tarball_fn] tarball_tgt
    >>= fun () ->
    to_file ~ctxt (sexp_of_tarball tarball) mthd


(** Try to load .sexp  
  *)
let check_file ~ctxt tarball f_test f_doesnt_exist f_invalid =
  let sexp_fn =
    sexp_of_tarball tarball
  in
    catch 
      (fun () ->
         if Sys.file_exists sexp_fn then
           begin
             from_file 
               ~ctxt
               (sexp_of_tarball tarball)
             >>=
             f_test
           end
         else
           begin
             f_doesnt_exist ()
           end)
      (function
         | Of_sexp_error _ 
         | Parse_error _ ->
             (* the .sexp file is corrupted, probably related
              * to the fact that we write and read on it at 
              * the same time. Ignore this error
              *)
             f_invalid ()

         | e ->
             fail e)

(** Answers for {check_step2}
  *)
type check_step2_t = 
  | Step2_NotYet
  | Step2_Reached of upload_t * ODBCompletion.t
  | Step2_Bypassed

(** Wait that a file reach Step2 or disappear (step 1 -> step 2)
  *)
let check_step2 ~ctxt tarball = 
  check_file ~ctxt tarball
    (function
       | Step1_JustUploaded _ ->
           return Step2_NotYet
             
       | Step2_UserEditable (ut, ct) ->
           return (Step2_Reached (ut, ct))
             
       | Step3_UserValidated _ ->
           return Step2_Bypassed)

    (fun () -> 
       return Step2_Bypassed)

    (fun () -> 
       return Step2_NotYet)

(** Validate a tarball (step 2 -> step 3)
  *)
let validate ~ctxt mthd publink pkg ver ord oasis_fn tarball = 
  let sexp_fn = 
    sexp_of_tarball tarball
  in
    to_file ~ctxt 
      sexp_fn
      (Step3_UserValidated 
         ({publink = publink; upload_method = mthd},
          pkg, ver, ord, oasis_fn))

(** Answers for {check_step3}
  *)
type check_step3_t =
  | Step3_NotYet 
  | Step3_Back1
  | Step3_Back2
  | Step3_Finished
  | Step3_Bypassed

(** Wait that a file go into archive (step3 -> )
  *)
let check_step3 ~ctxt tarball = 
  check_file ~ctxt tarball
    (function
       | Step1_JustUploaded _ ->
           return Step3_Back1

       | Step2_UserEditable _ ->
           return Step3_Back2
             
       | Step3_UserValidated _ ->
           return Step3_NotYet)

    (fun () -> 
       (* TODO: check in the log that we have really finished
        * the upload. If not -> Step3_Bypassed
        *)
       return Step3_Finished)

    (fun () -> 
       return Step3_NotYet)
