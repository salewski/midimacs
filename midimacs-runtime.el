(eval-when-compile
  (require 'cl))
(require 'midimacs-globals)

(defun midimacs-tick ()
  (when (memq midimacs-state '(playing recording))

    (midimacs-trigger-note-offs)
    (midimacs-trigger-events)
    (midimacs-incr-position)
    (setq midimacs-last-tick-seconds (float-time))

    (when (eq midimacs-state 'recording)
      (midimacs-remove-note-from-score
       midimacs-recording-score
       (midimacs-time- midimacs-song-time
                       (midimacs-score-start-time midimacs-recording-score)
                       (make-midimacs-time :tick -1)))) ;; one ahead

    ;; only update when we have to
    (when (= (midimacs-time-tick midimacs-song-time) 0)
      (midimacs-redraw-play))

    (run-at-time (midimacs-wait-time) nil 'midimacs-tick)))

(defun midimacs-incr-position ()
  (let ((1-tick (make-midimacs-time :tick 1)))
    (setq midimacs-abs-time (midimacs-time+ midimacs-abs-time 1-tick))
    (setq midimacs-song-time (midimacs-time+ midimacs-song-time 1-tick))

    (when (midimacs-time= midimacs-song-time midimacs-repeat-end)
      (setq midimacs-song-time midimacs-repeat-start))))

(defun midimacs-trigger-note-offs ()
  (let ((note-offs (midimacs-delete-message-heap-until midimacs-scheduled-note-offs midimacs-abs-time)))
    (dolist (note-off note-offs)
      (midimacs-midi-execute note-off))))

(defun midimacs-delete-message-heap-until (heap pos)
  (let ((el))
    (loop while (and (setq el (heap-root heap))
                     (midimacs-time<= (nth 0 el) pos))
          collect (nth 1 (heap-delete-root heap)))))

(defun midimacs-trigger-events ()
  (loop for (track event) in (midimacs-track-events-at-beat (midimacs-time-beat midimacs-song-time))
        do (let* ((code (midimacs-event-code event))
                  (init (midimacs-code-init code))
                  (run (midimacs-code-run code))
                  (channel (midimacs-track-channel track)))

             (when (and init
                        (midimacs-event-do-init event)
                        (eq (midimacs-time-tick midimacs-song-time) 0))

               (setf (midimacs-track-state track)
                     (funcall init
                              channel
                              midimacs-song-time
                              (midimacs-event-length event)
                              (midimacs-track-state track)))

               (setf (midimacs-track-last-init-time track) midimacs-abs-time))

             (when run
               (setf (midimacs-track-state track)
                     (funcall run
                              channel
                              midimacs-song-time
                              (midimacs-event-rel-time event midimacs-song-time)
                              (midimacs-track-state track)))))))

(defun midimacs-wait-time ()
  (let* ((tick-sec (/ 60.0 midimacs-bpm midimacs-ticks-per-beat))
         (expected-time-sec (+ midimacs-start-time-seconds
                               (* tick-sec (midimacs-time-to-ticks midimacs-abs-time))))
         (now (float-time))
         (drift (- now expected-time-sec)))
    (max 0 (- tick-sec drift))))


(provide 'midimacs-runtime)
