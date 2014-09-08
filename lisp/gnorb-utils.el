;;; gnorb-utils.el --- Common utilities for all gnorb stuff.

;; Copyright (C) 2014  Eric Abrahamsen

;; Author: Eric Abrahamsen <eric@ericabrahamsen.net>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'cl)
(require 'mailcap)
(require 'gnus)
;(require 'message)
(require 'bbdb)
(require 'org)
(require 'org-bbdb)
(require 'org-gnus)

(mailcap-parse-mimetypes)

(defgroup gnorb nil
  "Glue code between Gnus, Org, and BBDB."
  :tag "Gnorb")

(defcustom gnorb-trigger-todo-default 'prompt
  "What default action should be taken when triggering TODO
  state-change from a message? Valid values are the symbols note
  and todo, or prompt to pick one of the two."
  :group 'gnorb
  :type '(choice (const note)
		 (const todo)
		 (const prompt)))

(defun gnorb-prompt-for-bbdb-record ()
  "Prompt the user for a BBDB record."
  (let ((recs (bbdb-records))
	name)
    (while (> (length recs) 1)
      (setq name
	    (completing-read
	     (format "Filter records by regexp (%d remaining): "
		     (length recs))
	     (mapcar 'bbdb-record-name recs)))
      (setq recs (bbdb-search recs name name name nil nil)))
    (if recs
	(car recs)
      (error "No matching records"))))

(defvar gnorb-tmp-dir (make-temp-file "emacs-gnorb" t)
  "Temporary directory where attachments etc are saved.")

(defvar gnorb-message-org-ids nil
  "List of Org heading IDs from the outgoing Gnus message, used
  to mark mail TODOs as done once the message is sent."
  ;; The send hook either populates this, or sets it to nil, depending
  ;; on whether the message in question has an Org id header. Then
  ;; `gnorb-org-restore-after-send' checks for it and acts
  ;; appropriately, then sets it to nil.
  )

(defvar gnorb-window-conf nil
  "Save window configurations here, for restoration after mails
are sent, or Org headings triggered.")

(defvar gnorb-return-marker (make-marker)
  "Return point here after various actions, to be used together
with `gnorb-window-conf'.")

(defcustom gnorb-mail-header "X-Org-ID"
  "Name of the mail header used to store the ID of a related Org
  heading. Only used locally: always stripped when the mail is
  sent."
  :group 'gnorb
  :type 'string)

;;; this is just ghastly, but the value of this var is single regexp
;;; group containing various header names, and we want our value
;;; inside that group.
(eval-after-load 'message
  `(let ((ign-headers-list
	  (split-string message-ignored-mail-headers
			"|"))
	 (our-val (concat gnorb-mail-header "\\")))
     (unless (member our-val ign-headers-list)
       (setq ign-headers-list
	     `(,@(butlast ign-headers-list 1) ,our-val
	       ,@(last ign-headers-list 1)))
       (setq message-ignored-mail-headers
	     (mapconcat
	      'identity ign-headers-list "|")))))

(defun gnorb-restore-layout ()
  "Restore window layout and value of point after a Gnorb command.

Some Gnorb commands change the window layout (ie `gnorb-org-view'
or incoming email triggering). This command restores the layout
to what it was. Bind it to a global key, or to local keys in Org
and Gnus and BBDB maps."
  (interactive)
  (when (window-configuration-p gnorb-window-conf)
    (set-window-configuration gnorb-window-conf)
    (goto-char gnorb-return-marker)))

(defun gnorb-trigger-todo-action (arg &optional id)
  "Do the actual restore action. Two main things here. First: if
we were in the agenda when this was called, then keep us in the
agenda. Second: try to figure out the correct thing to do once we
reach the todo. That depends on `gnorb-trigger-todo-default', and
the prefix arg."
  (let* ((agenda-p (eq major-mode 'org-agenda-mode))
	 (todo-func (if agenda-p
			'org-agenda-todo
		      'org-todo))
	 (note-func (if agenda-p
			'org-agenda-add-note
		      'org-add-note))
	 root-marker ret-dest-todo action)
    (when (and (not agenda-p) id)
      (org-id-goto id))
    (setq root-marker (if agenda-p
			  (org-get-at-bol 'org-hd-marker)
			(point-at-bol))
	  ret-dest-todo (org-entry-get
			 root-marker "TODO"))
    (let ((ids (org-entry-get-multivalued-property
		root-marker gnorb-org-msg-id-key))
	  (sent-id (plist-get gnorb-gnus-sending-message-info :msg-id)))
      (when sent-id
	(gnorb-registry-make-entry
	 sent-id
	 (plist-get gnorb-gnus-sending-message-info :from)
	 (plist-get gnorb-gnus-sending-message-info :subject)
	 (org-id-get)
	 (plist-get gnorb-gnus-sending-message-info :group)))
      (setq action (cond ((not
			   (or (and ret-dest-todo
				    (null gnorb-org-mail-todos))
			       (member ret-dest-todo gnorb-org-mail-todos)))
			  'note)
			 ((eq gnorb-trigger-todo-default 'prompt)
			  (intern (completing-read
				   "Take note, or trigger TODO state change? "
				   '("note" "todo") nil t)))
			 ((null arg)
			  gnorb-trigger-todo-default)
			 (t
			  (if (eq gnorb-trigger-todo-default 'todo)
			      'note
			    'todo))))
      (map-y-or-n-p
       (lambda (a)
	 (format "Attach %s to heading? "
		 (file-name-nondirectory a)))
       (lambda (a) (org-attach-attach a nil 'mv))
       gnorb-gnus-capture-attachments
       '("file" "files" "attach"))
      (setq gnorb-gnus-capture-attachments nil)
      (if (eq action 'note)
	  (call-interactively note-func)
	(call-interactively todo-func)))))

(defun gnorb-scan-links (bound &rest types)
  ;; this function could be refactored somewhat -- lots of code
  ;; repetition. It also should be a little faster for when we're
  ;; scanning for gnus links only, that's a little slow. We should
  ;; probably use a different regexp based on the value of TYPES.
  ;;
  ;; This function should also *not* be responsible for unescaping
  ;; links -- we don't know what they're going to be used for, and
  ;; unescaped is safer.
  (unless (= (point) bound)
    (let (addr gnus mail bbdb)
      (while (re-search-forward org-any-link-re bound t)
	(setq addr (or (match-string-no-properties 2)
		       (match-string-no-properties 0)))
	(cond
	 ((and (memq 'gnus types)
	       (string-match "^<?gnus:" addr))
	  (push (substring addr (match-end 0)) gnus))
	 ((and (memq 'mail types)
	       (string-match "^<?mailto:" addr))
	  (push (substring addr (match-end 0)) mail))
	 ((and (memq 'bbdb types)
	       (string-match "^<?bbdb:" addr))
	  (push (substring addr (match-end 0)) bbdb))))
      `(:gnus ,gnus :mail ,mail :bbdb ,bbdb))))

(defun gnorb-msg-id-to-link (msg-id)
  (let ((server-group (gnorb-msg-id-to-group msg-id)))
    (when server-group
      (org-link-escape (concat server-group "#" msg-id)))))

(defun gnorb-msg-id-to-group (msg-id)
  "Given a message id, try to find the group it's in.

So far we're checking the registry, then the groups in
`gnorb-gnus-sent-groups'. Use search engines? Other clever
methods?"
  (let (candidates server-group)
    (catch 'found
      (when gnorb-tracking-enabled
	;; Make a big list of all the groups where this message might
	;; conceivably be.
	(setq candidates
	      (append (gnus-registry-get-id-key msg-id 'group)
		      gnorb-gnus-sent-groups))
	(while (setq server-group (pop candidates))
	  (when (and (stringp server-group)
		     (not
		      (string-match-p
		       "\\(nnir\\|nnvirtual\\|UNKNOWN\\)"
		       server-group))
		     (ignore-errors
		       (gnus-request-head msg-id server-group)))
		(throw 'found server-group))))
      (when (featurep 'notmuch)
	nil))))

;; Loading the registry

(defvar gnorb-tracking-enabled nil
  "Internal flag indicating whether Gnorb is successfully plugged
  into the registry or not.")

(defun gnorb-tracking-initialize ()
  "Start using the Gnus registry to track correspondences between
Gnus messages and Org headings. This requires that the Gnus
registry be in use, and should be called after the call to
`gnus-registry-initialize'."
  (require 'gnorb-registry)
  (add-hook
   'gnus-started-hook
   (lambda ()
     (unless (gnus-registry-install-p)
       (user-error "Gnorb tracking requires that the Gnus registry be installed."))
     (add-to-list 'gnus-registry-extra-entries-precious 'gnorb-ids)
     (add-to-list 'gnus-registry-track-extra 'gnorb-ids)
     (add-hook 'org-capture-mode-hook 'gnorb-registry-capture)
     (add-hook 'org-capture-prepare-finalize-hook 'gnorb-registry-capture-abort-cleanup)
     (setq gnorb-tracking-enabled t))))

(provide 'gnorb-utils)
;;; gnorb-utils.el ends here
