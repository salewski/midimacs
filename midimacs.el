;;; -*- lexical-binding: t; -*-

;; TODO:
;;
;; midimacs-quantize-region
;; split out midilib
;; package-ize
;; midimacs-started-notes channel; midimacs-sustained-notes
;; allow "meta-channels" >15

;; BUGS:
;; cannot show/hide timing when note is not parseable
;; enharmonic shifts when hiding/showing
;; cannot save when code doesn't parse
;; when midi server goes away we die

(eval-when-compile
  (require 'cl))
(require 'heap)
(require 'picture)

(require 'midimacs-globals)
(require 'midimacs-code-api)
(require 'midimacs-time)
(require 'midimacs-parse-seq)
(require 'midimacs-draw)
(require 'midimacs-score)
(require 'midimacs-buffer)
(require 'midimacs-pitch)
(require 'midimacs-runtime)
(require 'midimacs-save)
(require 'midimacs-util)
(require 'midimacs-midi)
(require 'midimacs-general-midi)

(define-derived-mode midimacs-seq-mode fundamental-mode "midimacs-seq-mode"
  (midimacs-extend-picture-mode)
  (setq buffer-read-only nil)
  (local-set-key (kbd "C-x C-[") 'midimacs-set-repeat-start)
  (local-set-key (kbd "C-x C-]") 'midimacs-set-repeat-end)
  (local-set-key (kbd "RET") 'midimacs-seq-enter)
  (local-set-key (kbd "C-x SPC") 'midimacs-toggle-play)
  (local-set-key (kbd "M-SPC") 'midimacs-toggle-play)
  (local-set-key (kbd "C-M-SPC") 'midimacs-play-here)
  (local-set-key (kbd "C-<return>") 'midimacs-position-here)
  (local-set-key (kbd "C-x C-r") 'midimacs-record-keyboard)
  (local-set-key (kbd "C-x C-s") 'midimacs-save)
  (local-set-key (kbd "C-x C-w") 'midimacs-save-as)
  (local-set-key (kbd "C-x C-f") 'midimacs-open)
  (local-set-key (kbd "C-x T") 'midimacs-tap-tempo-and-play)
  (local-set-key (kbd "C-x t") 'midimacs-tap-tempo)
  (local-set-key (kbd "C-x m") 'midimacs-merge-scores)
  (local-set-key (kbd "C-x s") 'midimacs-split-score)
  (setq-local after-change-functions '(midimacs-seq-after-change))
  (setq-local transient-mark-mode nil)
  (setq-local font-lock-defaults `(((,(midimacs-bad-track-regex) . font-lock-warning-face))))
  (setq truncate-lines t))

(define-derived-mode midimacs-seq-record-keyboard-mode midimacs-seq-mode "midimacs-seq-record-keyboard-mode"
  (setq buffer-read-only t)
  (let ((keyboard-notes (midimacs-keyboard-notes)))
    (loop for (char . note) in keyboard-notes
          do (local-set-key (kbd (string char)) (lexical-let ((pitch (midimacs-parse-pitch note)))
                                                  (lambda ()
                                                    (interactive)
                                                    (midimacs-record-key pitch)))))))

(define-derived-mode midimacs-code-mode emacs-lisp-mode "midimacs-code-mode"
  (define-key midimacs-code-mode-map (kbd "M-SPC") 'midimacs-toggle-play)
  (define-key midimacs-code-mode-map (kbd "C-x C-s") 'midimacs-save)
  (define-key midimacs-code-mode-map (kbd "C-x C-w") 'midimacs-save-as)
  (define-key midimacs-code-mode-map (kbd "C-x C-f") 'midimacs-open)
  (define-key midimacs-code-mode-map (kbd "C-c h") 'midimacs-code-score-hide-times)
  (define-key midimacs-code-mode-map (kbd "C-c s") 'midimacs-code-score-show-times)
  (define-key midimacs-code-mode-map (kbd "C-c C-c") 'eval-buffer))

;;;###autoload
(defun midimacs () "Start midimacs"
  (interactive)
  (switch-to-buffer (midimacs-buffer-seq-name))
  (midimacs-seq-mode)
  (midimacs-init))

(defun midimacs-init ()
  (setq midimacs-tracks '())
  (setq midimacs-codes (make-hash-table :test 'equal))
  (setq midimacs-song-time (make-midimacs-time))
  (setq midimacs-abs-time (make-midimacs-time))
  (setq midimacs-state 'stopped)
  (setq midimacs-start-time-seconds nil)
  (setq midimacs-filename nil)
  (setq midimacs-scheduled-note-offs (midimacs-make-scheduled-note-offs-heap))
  (setq midimacs-repeat-start (make-midimacs-time))
  (setq midimacs-repeat-end (make-midimacs-time :beat midimacs-length))
  (setq midimacs-repeat-start-overlay nil)
  (setq midimacs-repeat-end-overlay nil)
  (setq midimacs-play-overlay nil)
  (setq midimacs-recording-score nil)
  (setq midimacs-start-func nil)
  (setq midimacs-channel-default-velocities (make-hash-table))

  (midimacs-close-all-code-buffers)
  (midimacs-amidicat-proc-init)
  (midimacs-draw ""))

(defun midimacs-extend-picture-mode ()
  (use-local-map picture-mode-map)
  (set (make-local-variable 'picture-killed-rectangle) nil)
  (set (make-local-variable 'tab-stop-list) (default-value 'tab-stop-list))
  (set (make-local-variable 'picture-tab-chars)
       (default-value 'picture-tab-chars))
  (make-local-variable 'picture-vertical-step)
  (make-local-variable 'picture-horizontal-step)
  (setq truncate-lines t)
  (picture-set-motion 0 1))

(defun midimacs-seq-enter ()
  (interactive)
  (let ((code (midimacs-code-at-point)))
    (when code
      (midimacs-code-open-window code))))

(defun midimacs-set-repeat-start ()
  (interactive)
  (save-excursion
    (forward-char)
    (let ((new-repeat-start (make-midimacs-time :beat (midimacs-beat-at-point))))
      (midimacs-check-acceptable-repeat new-repeat-start midimacs-repeat-end)
      (setq midimacs-repeat-start new-repeat-start)))
  (midimacs-redraw-repeat-start))

(defun midimacs-set-repeat-end ()
  (interactive)
  (let ((new-repeat-end (make-midimacs-time :beat (midimacs-beat-at-point))))
    (midimacs-check-acceptable-repeat midimacs-repeat-start new-repeat-end)
    (setq midimacs-repeat-end new-repeat-end))
  (midimacs-redraw-repeat-end))

(defun midimacs-check-acceptable-repeat (start end)
  (let ((beats (- (midimacs-time-beat start) (midimacs-time-beat end))))
    (when (= beats 0)
      (user-error "repeat start and repeat end must be different"))))

(defun midimacs-toggle-play ()
  (interactive)
  (cond ((eq midimacs-state 'playing) (midimacs-stop))
        ((eq midimacs-state 'recording) (midimacs-stop-recording))
        ((eq midimacs-state 'stopped) (midimacs-play))))

(defun midimacs-position-here ()
  (interactive)
  (let ((beat (midimacs-beat-at-point)))
    (midimacs-check-beat beat)
    (setq midimacs-song-time (make-midimacs-time :beat beat)))
  (midimacs-redraw-play))

(defun midimacs-play-here ()
  (interactive)
  (midimacs-position-here)
  (when (eq midimacs-state 'stopped)
    (midimacs-play)))

(defun midimacs-play ()
  (midimacs-prepare-play)
  (setq midimacs-state 'playing)
  (midimacs-redraw-play)
  (midimacs-tick))

(defun midimacs-prepare-play ()
  (setq midimacs-start-time-seconds (float-time))
  (setq midimacs-abs-time (make-midimacs-time))
  (when midimacs-start-func
    (funcall midimacs-start-func)))

(defun midimacs-record-keyboard ()
  (interactive)
  (if (eq midimacs-state 'stopped)
      (progn
        (midimacs-seq-record-keyboard-mode)
        (midimacs-record))
    (user-error "Can only start recording from stopped")))

(defun midimacs-record ()
  (midimacs-prepare-play)
  (setq midimacs-recording-score (midimacs-get-recording-score)) ;; can fail and die here
  (setq midimacs-state 'recording)
  (midimacs-redraw-play)
  (midimacs-tick))

(defun midimacs-stop ()
  (midimacs-midi-flush-note-offs)
  (setq midimacs-state 'stopped)
  (midimacs-redraw-play))

(defun midimacs-stop-recording ()
  (midimacs-stop)

  (with-current-buffer (midimacs-buffer-seq)
    (midimacs-seq-mode))
  (with-current-buffer (midimacs-score-buffer midimacs-recording-score)
    (setq midimacs-recording-score nil)
    (midimacs-code-update)))

(defun midimacs-set-tempo (bpm)
  (interactive "nBeats per minute: ")
  (let ((state midimacs-state))
    (midimacs-stop)
    (setq midimacs-bpm bpm)
    (when (eq state 'playing) ; TODO: recording
      (midimacs-play))))

(defun midimacs-tap-tempo ()
  (interactive)
  (let ((tempo (midimacs-read-tempo-taps)))
    (setq midimacs-bpm tempo)
    (message (format "Setting tempo to %.2f" tempo))))

(defun midimacs-tap-tempo-and-play ()
  (interactive)
  (midimacs-tap-tempo)
  (when (eq midimacs-state 'stopped)
    (midimacs-play)))


(provide 'midimacs)
;;; midimacs.el ends here

;; Local variables:
;; byte-compile-warnings: (not cl-functions)
;; End:
