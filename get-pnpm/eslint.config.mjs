import eslintConfig from '@pnpm/eslint-config'
import * as regexpPlugin from 'eslint-plugin-regexp'

export default [
  {
    ignores: ['**/fixtures', '**/node_modules', 'lib'],
  },
  ...eslintConfig,
  regexpPlugin.configs['flat/recommended'],
  {
    files: ['test/**/*.ts'],
    rules: {
      // The tests run on node:test, whose test() and describe() return a
      // promise that the runner itself awaits.
      '@typescript-eslint/no-floating-promises': ['error', {
        allowForKnownSafeCalls: [
          { from: 'package', package: 'node:test', name: ['describe', 'it', 'suite', 'test'] },
        ],
      }],
    },
  },
]
