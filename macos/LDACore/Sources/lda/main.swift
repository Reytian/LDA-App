//
//  main.swift
//  lda
//
//  Executable entry point for the `lda` CLI. Delegates to LDACLI so the command
//  logic lives in a library target and stays unit-testable.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import LDACLI

LDACLI.main()
