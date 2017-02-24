;;; package -- Summary
;;; Commentary:
(require 'package)
;;; Code:
(add-to-list 'package-archives '("melpa" . "http://melpa.org/packages/"))
(package-initialize)
(if(not(package-installed-p 'evil))
  (package-refresh-contents))

(defvar my-packages
  '(evil
    evil-leader
    helm
    company
    linum-relative
    projectile
    helm-projectile
    magit
    coffee-mode
    helm-ag
    solarized-theme
    rust-mode
    flycheck
    flycheck-rust
    ))

(dolist (p my-packages)
  (when (not (package-installed-p p))
(package-install p)))

(require 'evil)
(evil-mode 1)
(projectile-global-mode)
(global-set-key (kbd "M-x") 'helm-M-x)

;; gui bits
(menu-bar-mode -1)
(toggle-scroll-bar -1)
(tool-bar-mode -1)


(global-company-mode)
(global-flycheck-mode)
(linum-relative-global-mode)
(load-theme 'solarized-light t)
(add-hook 'flycheck-mode-hook #'flycheck-rust-setup)
(setq company-minimum-prefix-length 2)
(setq company-idle-delay 0)
(setq coffee-tab-width 2)
(setq-default indicate-empty-lines t)
(setq make-backup-files nil)
(global-evil-leader-mode)

;; shortcuts
(evil-leader/set-leader "<SPC>")
(evil-leader/set-key
  "g s" 'magit-status
  "g l" 'magit-log-all
  "f" 'helm-projectile
  "b" 'helm-mini
  "a" 'helm-do-ag-project-root)
(modify-syntax-entry ?_ "w" (standard-syntax-table))
(provide '.emacs)
;;; .emacs ends here
