;;; seriesTracker.el --- Series tracker -*- lexical-binding: t; -*-
;; Package-Requires: ((dash "2.12.1"))
;;; Commentary:
;;; Code:

;;; Requirements

(require 'url)                                                                  ; used to fetch api data
(require 'json)                                                                 ; used to parse api response
(require 'dash)                                                                 ; threading etc.
(require 'transient)                                                            ; transient for command dispatch

;;; Helpers

;;;; alist-select

(defun st--utils-alist-select (fields alist)
  "Keep only FIELDS in ALIST by constructing a new alist containing only these elements.

alist-select '(a c) '((a .1) (b , \"b\") (c . c)
returns '((a . 1) (c . c))"

  (->> fields
    reverse
    (--reduce-from (acons it (alist-get it alist) acc)
                   nil)))

;;;; array-select

(defun st--utils-array-select (fields array)
  "Keep only FIELDS in every alist in the ARRAY.

array-select '(a c) '(((a . 1) (b . 2) (c . c)) ((a . 3) (b . 5) (c . d)))
returns '(((a . 1) (c . c)) ((a . 3) (c . d)))"

  (--map (st--utils-alist-select fields it) array))

;;;; array-pull

(defun st--utils-array-pull (field array)
  "Keep only FIELD in every alist in the ARRAY and flatten.

array-pull 'a '(((a . 1) (b . 2)) ((a . 3) (b . 4)))
returns '(1 3)"

  (--map (alist-get field it) array))

;;;; getJSON

(defun st--getJSON (url-buffer)
  "Parse the JSON in the URL-BUFFER returned by url."

  (with-current-buffer url-buffer
    (goto-char (point-max))
    (move-beginning-of-line 1)
    (json-read-object)))

;;; episodate.com API

;;;; search

(defun st--search (name)
  "Search episodate.com db for NAME."

  (->> (let ((url-request-method "GET"))
         (url-retrieve-synchronously (concat "https://www.episodate.com/api/search?q=" name)))
    st--getJSON
    (st--utils-alist-select '(tv_shows))
    car
    cdr
    (st--utils-array-select '(id name start_date status network permalink))))

;;;; series

(defun st--episodes (series)
  (setf (alist-get 'episodes series)
        (mapcar (lambda (x) x) (alist-get 'episodes series)))
  series)

(defun st--series (id)
  "Get series ID info."

  (->> (let ((url-request-method "GET"))
         (url-retrieve-synchronously (concat "https://www.episodate.com/api/show-details?q=" (int-to-string id))))
    st--getJSON
    car
    (st--utils-alist-select '(id name start_date status episodes))
    st--episodes))

;;; Internal API

;;;; Data model

(defvar st--data
  nil
  "Internal data containing followed series and episode.

Of the form :

'(((id . seriesId) (props . value) (…) (episodes ((id . episodeId) (watched . t) (props.value) (…))
                                                 ((id . episodeId) (watched . nil) (props.value) (…)))))
  ((id . seriesId) (…) (episodes ((id . episodeId) (…))
                                 ((id . episodeId) (…)))))

series props are name and start_date.
episodes props are season, episode, name, and air_date.")

;;;; Add/remove
;;;;; Add series

(defun st--add (id)
  "Add series with ID to st--data.
Adding an already existing series resets it."

  (setq st--data
        (--> st--data
          (--remove (= id (alist-get 'id it)) it)
          (-snoc it (--> (st--series id))))))

;;;;; Remove series

(defun st--remove (id)
  "Remove series with ID from st--data."

  (setq st--data
        (--remove (= id (alist-get 'id it)) st--data)))

;;;; Watch

;;;;; Watch episode

(defun st--watch-episode (id seasonN episodeN watch)
  "Watch EPISODEN of SEASONN in series ID."

  (->> st--data
    (--map-when (= id (alist-get 'id it))
                (setf (alist-get 'episodes it)
                      (--map-when (and (= seasonN (alist-get 'season it))
                                       (= episodeN (alist-get 'episode it)))
                                  (progn
                                    (setf (alist-get 'watched it) watch)
                                    it)
                                  (alist-get 'episodes it))))))

;;;;; Watch season

(defun st--watch-season (id seasonN watch)
  "Watch all episode in a season."

  (->> st--data
    (--map-when (= id (alist-get 'id it))
                (setf (alist-get 'episodes it)
                      (--map-when (= seasonN (alist-get 'season it))
                                  (progn
                                    (setf (alist-get 'watched it) watch)
                                    it)
                                  (alist-get 'episodes it))))))

;;;;; Watch series

(defun st--watch-series (id watch)
  "Watch all episodes in series ID."

  (->> st--data
    (--map-when (= id (alist-get 'id it))
                (setf (alist-get 'episodes it)
                      (--map (progn
                               (setf (alist-get 'watched it) watch)
                               it)
                             (alist-get 'episodes it))))))

;;;;; Watch all episodes up to episode

(defun st--watch-up (id seasonN episodeN)
  "Watch all episodes up to EPISODEN of SEASON in series ID."

  (->> st--data
    (--map-when (= id (alist-get 'id it))
                (setf (alist-get 'episodes it)
                      (--map-when (or (< (alist-get 'season it) seasonN)
                                      (and (= (alist-get 'season it) seasonN)
                                           (<= (alist-get 'episode it) episodeN)))
                                  (progn
                                    (setf (alist-get 'watched it) t)
                                    it)
                                  (alist-get 'episodes it))))))

;;;; Query updates

(defun st--update ()
  "Update all non-finished shows."

  (->> st--data
    (--map-when (string-equal "Running" (alist-get 'status it))
                (st--update-series it))))

(defun st--update-series (series)
  "Update the SERIES."

  (let* ((new (st--series (alist-get 'id series)))
         (newEp (alist-get 'episodes new))
         (status (alist-get 'status new))
         (watched (--find-indices (alist-get 'watched it) (alist-get 'episodes series)))
         (newEps (--map-indexed (if (-contains? watched it-index)
                                    (progn
                                      (setf (alist-get 'watched it) t)
                                      it)
                                  it) newEp)))

    (when (string-equal status "Ended") (setf (alist-get 'status series) "Ended"))
    (setf (alist-get 'episodes series) newEps)

    series))

;;;; Load/save data

(defvar st--file
  "~/.emacs.d/st.el"
  "Location of the save file")

(defun st--save ()
  (with-temp-file st--file
    (let ((print-level nil)
          (print-length nil))
      (prin1 st--data (current-buffer)))))

(defun st--load ()
  (with-temp-buffer
    (insert-file-contents st--file)
    (cl-assert (eq (point) (point-min)))
    (setq st--data (read (current-buffer)))))

;;; Interface

;;;; Faces

(defface st-series
  '((t (:height 1.9 :weight bold :foreground "DeepSkyBlue")))
  "Face for series names")

(defface st-finished-series
  '((t (:height 2.0 :weight bold :foreground "DimGrey")))
  "Face for finished series names")

(defface st-season
  '((t (:height 1.7 :weight bold :foreground "MediumPurple")))
  "Face for seasons")

(defface st-watched
  '((t (:foreground "DimGrey" :strike-through t)))
  "Face for watched episodes")

;;;; Draw buffer

(defun st--refresh ()
  "Refresh the st buffer."

  (let ((line (line-number-at-pos)))
    (st--draw-buffer)
    (goto-line line))

  (cond ((eq fold-cycle 'st-all-folded)
         (st-fold-all))
        ((eq fold-cycle 'st-all-unfolded)
         (st-unfold-all))
        ((eq fold-cycle 'st-series-folded)
         (st-unfold-all-series))))

(defun st--draw-buffer ()
  "Draw the buffer.
Erase first then redraw the whole buffer."

  (let ((inhibit-read-only t))
    (erase-buffer)
    (-each st--data 'st--draw-series)
    (delete-char -1)))

(defun st--draw-series (series)
  "Print the series id and name."

  (let ((id (alist-get 'id series))
        (name (alist-get 'name series))
        (finished (string-equal "Ended" (alist-get 'status series)))
        (episodes (alist-get 'episodes series)))
    (let ((start (point)))
      (insert (concat name "\n"))
      (set-text-properties start (point)
                           `(st-series ,id
                             st-season nil
                             st-episode nil))
      (if finished
          (put-text-property start (point) 'face 'st-finished-series)
        (put-text-property start (point) 'face 'st-series))
      (when (--all? (alist-get 'watched it)
                    (alist-get 'episodes series))
        (put-text-property start (point) 'invisible 'st-watched)))
    (--each episodes (st--draw-episode series it))))

(defun st--draw-episode (series episode)
  "Print the episode id, S**E**, and name."

  (let ((id (alist-get 'id series))
        (season (alist-get 'season episode))
        (episode (alist-get 'episode episode))
        (name (alist-get 'name episode))
        (air_date (alist-get 'air_date episode))
        (watched (alist-get 'watched episode)))
    (when (= episode 1)
      (let ((start (point)))
        (insert (concat "Season " (int-to-string season) "\n"))
        (set-text-properties start (point)
                             `(face st-season
                                    st-series ,id
                                    st-season ,season
                                    st-episode nil))
        (when (--all? (alist-get 'watched it)
                      (--filter (= season (alist-get 'season it))
                                (alist-get 'episodes series)))
          (put-text-property start (point) 'invisible 'st-watched))))
    (let ((start (point)))
      (insert air_date)
      (let ((end-date (point)))
        (insert (concat " " (format "%02d" episode) " - " name "\n"))
        (set-text-properties start (point)
                             `(face default
                                    st-series ,id
                                    st-season ,season
                                    st-episode ,episode))
        (if (time-less-p (date-to-time air_date)
                         (current-time))
            (put-text-property start end-date 'face '(t ((:foreground "MediumSpringGreen"))))
          (put-text-property start end-date 'face '(t ((:foreground "firebrick"))))))
      (when watched
        (set-text-properties start (point)
                             `(face st-watched
                                    st-series ,id
                                    st-season ,season
                                    st-episode ,episode
                                    invisible st-watched))))))

;;;; Movements

(defun st-up ()
  "Move up in the hierarchy."

  (interactive)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond (episode (goto-char (previous-single-property-change (point) 'st-season)))
              (season (goto-char (previous-single-property-change (point) 'st-series)))))
    (message "Not in st buffer!")))

(defun st-prev ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (goto-char (previous-single-property-change (point) 'st-season nil (point-min))))
    (message "Not in st buffer!"))
  (when (and (= 1 (point))
             (invisible-p 1))
    (st-next))
  (when (invisible-p (point)) (st-prev)))

(defun st-next ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (goto-char (next-single-property-change (point) 'st-season nil (point-max))))
    (message "Not in st buffer!"))
  (when (invisible-p (point)) (st-next)))

(defun st--next-any ()
  "Move up in the hierarchy, including invisible headings."

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (goto-char (next-single-property-change (point) 'st-season nil (point-max))))
    (message "Not in st buffer!")))

(defun st-prev-same ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond ((or episode season) (goto-char (previous-single-property-change (point) 'st-season nil (point-min))))
              (series (goto-char (previous-single-property-change (point) 'st-series nil (point-min))))))
    (message "Not in st buffer!"))
  (when (and (= 1 (point))
             (invisible-p 1))
    (st-next))
  (when (invisible-p (point)) (st-prev-same)))

(defun st-next-same ()
  "Move up in the hierarchy."

  (interactive)

  (setq disable-point-adjustment t)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (progn (when (= 1 (point))
               (goto-char 2))
             (let ((series (get-text-property (point) 'st-series))
                   (season (get-text-property (point) 'st-season))
                   (episode (get-text-property (point) 'st-episode)))
               (cond ((or episode season) (goto-char (next-single-property-change (point) 'st-season nil (point-max))))
                     (series (goto-char (next-single-property-change (point) 'st-series nil (point-max)))))))
    (message "Not in st buffer!"))
  (when (invisible-p (point)) (st-next-same)))

;;;; Folding

(defun st-fold-at-point ()
  "Fold the section at point."

  (interactive)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond (episode (st-fold-episodes))
              (season (st-fold-season))
              (t (st-fold-series))))
    (message "Not in st buffer!")))

(defun st-fold-episodes ()
  "Fold the episodes at point."

  (let* ((season-start (previous-single-property-change (point) 'st-season))
         (fold-start (next-single-property-change season-start 'st-episode))
         (fold-end (next-single-property-change (point) 'st-season nil (point-max)))
         (overlay (make-overlay fold-start fold-end)))
    (overlay-put overlay 'invisible 'st-season)))

(defun st-fold-season ()
  "Fold the season at point."

  (let* ((fold-start (next-single-property-change (point) 'st-episode))
         (fold-end (next-single-property-change (point) 'st-season nil (point-max)))
         (overlay (make-overlay fold-start fold-end)))
    (overlay-put overlay 'invisible 'st-season)))

(defun st-fold-series ()
  "Fold the series at point."

  (let* ((fold-start (next-single-property-change (point) 'st-season))
         (fold-end (next-single-property-change (point) 'st-series nil (point-max)))
         (overlay (when (and fold-start fold-end) (make-overlay fold-start fold-end))))
    (when overlay (overlay-put overlay 'invisible 'st-series))))

(defun st-unfold-at-point ()
  "Unfold the section at point."

  (interactive)

  (if (and (string-equal (buffer-name) "st") (string-equal mode-name "st"))
      (let ((series (get-text-property (point) 'st-series))
            (season (get-text-property (point) 'st-season))
            (episode (get-text-property (point) 'st-episode)))
        (cond (season (st-unfold-season))
              (t (st-unfold-series))))
    (message "Not in st buffer!")))

(defun st-unfold-season ()
  "Fold the season at point."

  (let ((fold-start (next-single-property-change (point) 'st-episode))
        (fold-end (next-single-property-change (point) 'st-season)))
    (remove-overlays fold-start fold-end 'invisible 'st-season)))

(defun st-unfold-series ()
  "Fold the series at point."

  (let ((fold-start (next-single-property-change (point) 'st-season))
        (fold-end (next-single-property-change (point) 'st-series)))
    (remove-overlays fold-start fold-end 'invisible 'st-series)))

;;;;; Cycle folding

(defvar fold-cycle 'st-all-folded)

(defun st-cycle ()
  "Cycle folding."

  (interactive)

  (cond ((eq fold-cycle 'st-all-folded)
         (st-unfold-all-series)
         (setq fold-cycle 'st-series-folded))
        ((eq fold-cycle 'st-series-folded)
         (st-unfold-all)
         (setq fold-cycle 'st-all-unfolded))
        ((eq fold-cycle 'st-all-unfolded)
         (st-fold-all)
         (setq fold-cycle 'st-all-folded))))

(defun st-unfold-all ()
  "Unfold everything."

  (interactive)

  (remove-overlays (point-min) (point-max) 'invisible 'st-series)
  (remove-overlays (point-min) (point-max) 'invisible 'st-season))

(defun st-fold-all ()
  "Fold everything."

  (interactive)

  (save-excursion
    (st-unfold-all)
    (goto-char 1)
    (while (< (point)
              (point-max))
      (st-fold-at-point)
      (st--next-any))))

(defun st-unfold-all-series ()
  "Unfold all series."

  (interactive)

  (st-fold-all)
  (remove-overlays (point-min) (point-max) 'invisible 'st-series))

;;;; Transient

(defvar st-show-watched "hide")

(defvar st-sorting-type "next")

(transient-define-prefix st-dispatch ()
  "Command dispatch for st."

  ["Series"
   :if-mode st-mode
   [("a" "Search and add a series" st-search)
    ("d" "Delete a series" st-remove)]
   [("ww" "Watch at point" st-watch)
    ("wu" "Watch up to point" st-watch-up)
    ("u" "Unwatch at point" st-unwatch)]
   [("U" "Update and refresh the buffer" st-update)]]

  ["Display"
   :if-mode st-mode
   [("W" st-infix-watched)
    ("S" st-infix-sorting)]]

  ["Load/Save"
   :if-mode st-mode
   [("s" "Save database" st-save)
    ("l" "Load database" st-load)
    ("f" st-infix-savefile)]]
  )

(defclass st-transient-variable (transient-variable)
  ((variable :initarg :variable)))

(defclass st-transient-variable:choice (st-transient-variable)
  ((name :initarg :name)
   (choices :initarg :choices)
   (default :initarg :default)
   (action :initarg :action)))

(cl-defmethod transient-init-value ((obj st-transient-variable))
  (oset obj value (eval (oref obj variable))))

(cl-defmethod transient-infix-read ((obj st-transient-variable))
  (read-from-minibuffer "Save file: " (oref obj value)))

(cl-defmethod transient-infix-read ((obj st-transient-variable:choice))
  (let ((choices (oref obj choices)))
    (if-let* ((value (oref obj value))
              (notlast (cadr (member value choices))))
        (cadr (member value choices))
      (car choices))))

(cl-defmethod transient-infix-set ((obj st-transient-variable) value)
  (oset obj value value)
  (set (oref obj variable) value))

(cl-defmethod transient-infix-set ((obj st-transient-variable:choice) value)
  (oset obj value value)
  (set (oref obj variable) value)
  (funcall (oref obj action)))

(cl-defmethod transient-format-value ((obj st-transient-variable))
  (let ((value (oref obj value)))
    (concat
     (propertize "(" 'face 'transient-inactive-value)
     (propertize value 'face 'transient-value)
     (propertize ")" 'face 'transient-inactive-value))))

(cl-defmethod transient-format-value ((obj st-transient-variable:choice))
  (let* ((variable (oref obj variable))
         (choices  (oref obj choices))
         (value    (oref obj value)))
    (concat
     (propertize "[" 'face 'transient-inactive-value)
     (mapconcat (lambda (choice)
                  (propertize choice 'face (if (equal choice value)
                                               (if (member choice choices)
                                                   'transient-value
                                                 'font-lock-warning-face)
                                             'transient-inactive-value)))
                (if (and value (not (member value choices)))
                    (cons value choices)
                  choices)
                (propertize "|" 'face 'transient-inactive-value))
     (propertize "]" 'face 'transient-inactive-value))))

(transient-define-infix st-infix-watched ()
  :class 'st-transient-variable:choice
  :choices '("show" "hide")
  :variable 'st-show-watched
  :description "Watched"
  :action 'st--apply-watched)

(defun st--apply-watched ()
  "Switch visibility for watched episodes."

  (if (-contains? buffer-invisibility-spec 'st-watched)
      (when (string-equal st-show-watched "show") (remove-from-invisibility-spec 'st-watched))
    (when (string-equal st-show-watched "hide") (add-to-invisibility-spec 'st-watched))))

(transient-define-infix st-infix-sorting ()
  :class 'st-transient-variable:choice
  :choices '("alpha" "next")
  :variable 'st-sorting-type
  :description "Sorting"
  :action 'st--apply-sort)

(defun st--apply-sort ()
  (cond ((string-equal st-sorting-type "alpha") (st-sort-alpha))
        ((string-equal st-sorting-type "next") (st-sort-next))))

(transient-define-infix st-infix-savefile ()
  :class 'st-transient-variable
  :variable 'st--file
  :description "Save file")

;;;; Load/save data

(defun st-save ()
  (interactive)
  (st--save))

(defun st-load ()
  (interactive)
  (st--load)
  (st--refresh))

;;;; Add series

(defun st-search ()

  (interactive)

  (let* ((searchterm (read-from-minibuffer "Search: "))
         (series-list (st--search searchterm))
         (names-list (st--utils-array-pull 'permalink series-list))
         (nametoadd (completing-read "Options: " names-list))
         (toadd (alist-get 'id (-find (lambda (series) (string-equal nametoadd (alist-get 'permalink series))) series-list))))
    (st--add toadd)
    (st--apply-sort)
    (st--refresh)))

;;;; Remove series

(defun st-remove ()
  "Remove series at point."

  (interactive)

  (let ((inhibit-read-only t)
        (series (get-text-property (point) 'st-series))
        (start (previous-single-property-change (1+ (point)) 'st-series))
        (end (next-single-property-change (point) 'st-series)))
    (when (y-or-n-p "Are you sure you want to delete this series? ")
      (st--remove series)
      (delete-region start end))))

;;;; (un)Watch episodes

(defun st-toggle-watch ()
  "Toggle watch at point.
The element under the cursor is used to decide whether to watch or unwatch."

  (interactive)

  (let* ((watched (get-char-property-and-overlay (point) 'invisible))
         (watch (not (-contains? watched 'st-watched))))
    (st-watch watch)))

(defun st-watch (watch)
  "Watch at point. If UNWATCH, unwatch at point."

  (interactive)

  (let ((inhibit-read-only t)
        (series (get-text-property (point) 'st-series))
        (season (get-text-property (point) 'st-season))
        (episode (get-text-property (point) 'st-episode)))
    (cond (episode (st-watch-episode series season episode watch))
          (season (st-watch-season series season watch))
          (t (st-watch-series series watch))))
  (forward-line))

(defun st-watch-episode (id seasonN episodeN watch)
  "Watch an episode."

  (let ((start (previous-single-property-change (1+ (point)) 'st-episode))
        (end (next-single-property-change (point) 'st-episode)))
    (if watch
        (progn
          (put-text-property start end 'invisible 'st-watched)
          (put-text-property start end 'face 'st-watched))
      (put-text-property start end 'invisible nil)
      (put-text-property start end 'face 'default)
      (if (time-less-p (date-to-time (buffer-substring start (+ start 19)))
                       (current-time))
          (put-text-property start (+ start 19) 'face '(t ((:foreground "MediumSpringGreen"))))
        (put-text-property start (+ start 19) 'face '(t ((:foreground "firebrick")))))))

  (st--watch-episode id seasonN episodeN watch))

(defun st-watch-season (id seasonN watch)

  (let* ((start-season (previous-single-property-change (1+ (point)) 'st-season))
         (start (next-single-property-change (1+ (point)) 'st-episode))
         (end (next-single-property-change start 'st-season)))

    (if watch
        (progn
          (put-text-property start-season end 'invisible 'st-watched)
          (put-text-property start end 'face 'st-watched))
      (put-text-property start-season end 'invisible nil)
      (put-text-property start end 'face 'default)))

  (st--watch-season id seasonN watch))

(defun st-watch-series (id watch)
  "Watch all episode in a series."

  (let* ((start-series (previous-single-property-change (1+ (point)) 'st-series))
         (start (next-single-property-change (1+ (point)) 'st-episode))
         (end (next-single-property-change start 'st-series)))

    (if watch
        (progn
          (put-text-property start-series end 'invisible 'st-watched)
          (put-text-property start end 'face 'st-watched))
      (put-text-property start-series end 'invisible nil)
      (put-text-property start end 'face 'default)))

  (st--watch-series id watch))

(defun st-watch-up ()
  "Watch up to episode at point."

  (interactive)

  (let* ((inhibit-read-only t)
         (series (get-text-property (point) 'st-series))
         (season (get-text-property (point) 'st-season))
         (episode (get-text-property (point) 'st-episode))
         (start-series (previous-single-property-change (1+ (point)) 'st-series))
         (start-season (next-single-property-change start-series 'st-season))
         (start (next-single-property-change start-season 'st-episode))
         (end (next-single-property-change (1+ (point)) 'st-episode)))
    (when episode
      (st--watch-up series season episode)
      (unless (= 1 season) (put-text-property start-season start 'invisible 'st-watched))
      (put-text-property start end 'invisible 'st-watched)
      (put-text-property start end 'face 'st-watched)))

  (forward-line))


;;;; Sort series

(defun st-sort-next ()
  "Sort series by date of next episode to watch."

  (interactive)

  (defun first-next-date (series)
    (let ((dates (->> series
                   (alist-get 'episodes)
                   (--filter (not (alist-get 'watched it))))))
      (if dates
          (->> dates
            (st--utils-array-pull 'air_date)
            (--map (car (date-to-time it)))
            -min)
        0)))

  (defun comp (a b)
    (< (first-next-date a)
       (first-next-date b)))

  (setq st--data (-sort 'comp st--data))

  (st--refresh))

(defun st-sort-alpha ()
  "Sort alphabetically."

  (interactive)

  (defun comp (a b)
    (string< (alist-get 'name a)
             (alist-get 'name b)))

  (setq st--data (-sort 'comp st--data))

  (st--refresh))

;;;; Create mode

(defun st-update ()
  "Update the db and refresh the buffer."

  (interactive)

  (st--update)
  (st--refresh))

(defun st ()
  "Run ST"

  (interactive)

  (switch-to-buffer "st")
  (st-mode)
  (st-load)
  (st--apply-watched)
  (st--refresh))

(define-derived-mode st-mode special-mode "st"
  "Series tracking with episodate.com."

  (setq-local buffer-invisibility-spec '(t st-series st-season))

  ;; keymap

  (local-set-key "d" 'previous-line)
  (local-set-key "s" 'next-line)

  (local-set-key "ð" 'st-prev)
  (local-set-key "ß" 'st-next)

  (local-set-key "Þ" 'st-up)
  (local-set-key "Ð" 'st-prev-same)
  (local-set-key "ẞ" 'st-next-same)

  (local-set-key "þ" 'st-fold-at-point)
  (local-set-key "®" 'st-unfold-at-point)

  (local-set-key "h" 'st-dispatch)
  (local-set-key "U" 'st-update)
  (local-set-key "a" 'st-search)
  (local-set-key "w" 'st-toggle-watch)
  (local-set-key [tab] 'st-cycle))

;;; Postamble

(provide 'seriesTracker)

;;; seriesTracker.el ends here
