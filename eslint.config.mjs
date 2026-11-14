// ESLint flat config (ESLint 9). Same rules as the former .eslintrc:
// JavaScript Standard Style + recommended Svelte rules.
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { FlatCompat } from '@eslint/eslintrc'
import svelte from 'eslint-plugin-svelte'
import globals from 'globals'

const compat = new FlatCompat({ baseDirectory: path.dirname(fileURLToPath(import.meta.url)) })

export default [
  {
    ignores: [
      '**/node_modules/**',
      '**/build/**',
      '**/dist/**',
      '**/*.min.*',
      '**/*.build.*',
      'capacitor/android/**',
      'capacitor/ios/**'
    ]
  },
  ...compat.extends('standard'),
  ...svelte.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'module',
      globals: {
        ...globals.browser,
        ...globals.node,
        ...globals.worker,
        launchQueue: 'readonly',
        FileSystemHandle: 'readonly',
        FileSystemFileHandle: 'readonly',
        FileSystemDirectoryHandle: 'readonly',
        FileSystemWritableFileStream: 'readonly',
        ClipboardItem: 'readonly',
        queryLocalFonts: 'readonly'
      }
    },
    rules: {
      'n/no-callback-literal': 0,
      // eslint-plugin-import (pulled in by eslint-config-standard 17) predates ESLint 9 and crashes on it.
      'import/export': 0,
      'import/first': 0,
      'import/no-absolute-path': 0,
      'import/no-duplicates': 0,
      'import/no-named-default': 0,
      'import/no-webpack-loader-syntax': 0
    }
  },
  {
    files: ['**/*.svelte'],
    rules: {
      'svelte/indent': ['error', { indent: 2, indentScript: true }],
      'no-self-assign': 0,
      'no-use-before-define': 0,
      'svelte/html-self-closing': ['error', 'always'],
      'svelte/html-closing-bracket-spacing': ['error', { startTag: 'never', endTag: 'never', selfClosingTag: 'always' }],
      'svelte/html-quotes': ['error', { prefer: 'single', dynamic: { quoted: false, avoidInvalidUnquotedInHTML: false } }],
      'svelte/shorthand-attribute': ['warn', { prefer: 'always' }],
      'svelte/spaced-html-comment': ['error', 'always']
    }
  }
]
