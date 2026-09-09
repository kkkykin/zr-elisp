EMACS ?= emacs
EMACSFLAGS ?= -Q -L .
FILE ?= $(wildcard *.el)
TEST_FILE ?= $(wildcard test/*-test.el)

.PHONY: all clean test check-parens byte-compile

CHECK_PARENS_EVAL = (dolist (name (list $(foreach file,$(FILE),"$(file)"))) (let ((file (expand-file-name name))) (unless (file-readable-p file) (error "File not found or unreadable: %s" file)) (with-temp-buffer (insert-file-contents file) (emacs-lisp-mode) (goto-char (point-min)) (condition-case err (progn (check-parens) (princ (format "check-parens: OK %s\n" file))) (error (princ (format "check-parens: %s:%d:%d: %s\n" file (line-number-at-pos) (current-column) (error-message-string err))) (kill-emacs 1))))))

all: test

clean:
	@find . -type f -name '*.elc' -print -delete

test:
	@$(EMACS) $(EMACSFLAGS) --batch \
		$(foreach file,$(TEST_FILE),-l "$(file)") \
		-f ert-run-tests-batch-and-exit

check-parens:
	@$(EMACS) $(EMACSFLAGS) --batch --eval '$(CHECK_PARENS_EVAL)'

byte-compile:
	@$(EMACS) $(EMACSFLAGS) --batch \
		-f batch-byte-compile $(foreach file,$(FILE),"$(file)")
