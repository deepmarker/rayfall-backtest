;;; rfl-fmt.el --- Indent Rayfall files the way rayfall-mode does -*- lexical-binding: t; -*-

;; emacs --batch -L RAYFALL_MODE_DIR -l tools/rfl-fmt.el [--check] FILE...
;;
;; Re-indents each FILE in place with `indent-region' under rayfall-mode
;; (https://github.com/vbmithr/tree-sitter-rayfall), so files match what the
;; editor produces. With --check, changes nothing and exits 1 if any FILE
;; would change.

;;; Code:

(require 'package)
(package-initialize)                    ; rayfall-mode's own dependencies
(require 'rayfall-mode)

(let ((check (equal (car command-line-args-left) "--check"))
      (changed nil))
  (when check (pop command-line-args-left))
  (dolist (file command-line-args-left)
    (with-temp-buffer
      (insert-file-contents file)
      (let ((before (buffer-string)))
        (rayfall-mode)
        (let ((inhibit-message t))
          (indent-region (point-min) (point-max)))
        (unless (equal before (buffer-string))
          (push file changed)
          (if check
              (message "%s: not formatted" file)
            (write-region nil nil file nil 'silent))))))
  (setq command-line-args-left nil)
  (kill-emacs (if (and check changed) 1 0)))

;;; rfl-fmt.el ends here
