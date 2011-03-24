
open Lwt
open ODBGettext
open Eliom_services
open Eliom_parameters
open Eliom_predefmod
open Common

let () =
  try 
    (* Initialize web context *)
    Lwt.ignore_result (Context.init ());
    Xhtml.register home Index.home_handler;
    Xhtml.register browse Browse.browse_handler;
    Xhtml.register view PkgVerView.view_handler;
    Redirection.register upload Upload.upload_handler;
    Xhtml.register contribute Index.contribute_handler;
    Xhtml.register about Index.about_handler;
    () 
  with e ->
    Printf.eprintf 
      (f_ "E: Exception raised during initialization: %s\n%!")
      (Printexc.to_string e)

let default = 
  (* Default = home *)
  Redirection.register_new_service
    ~path:[""]
    ~get_params:unit
    (fun sp () () ->
       return home)
