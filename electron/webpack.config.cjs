const { join, resolve } = require('path')

const mode = process.env.NODE_ENV?.trim() || 'development'

const commonConfig = require('common/webpack.config.cjs')

/** @type {import('webpack').WebpackOptionsNormalized[]} */
module.exports = [
  {
    ...commonConfig(__dirname),
    devServer: {
      devMiddleware: {
        writeToDisk: true
      },
      hot: true,
      client: {
        overlay: { errors: true, warnings: false, runtimeErrors: false }
      },
      port: 5000
    }
  },
  {
    devtool: 'source-map',
    stats: { warnings: false },
    entry: join(__dirname, 'src', 'preload', 'preload.js'),
    output: {
      path: join(__dirname, 'build'),
      filename: 'preload.js'
    },
    resolve: {
      aliasFields: []
    },
    mode,
    target: 'electron39.0-preload'
  },
  {
    devtool: 'source-map',
    entry: join(__dirname, 'src', 'main', 'main.js'),
    output: {
      path: join(__dirname, 'build'),
      filename: 'main.js'
    },
    externals: {
      '@paymoapp/electron-shutdown-handler': 'require("@paymoapp/electron-shutdown-handler")',
      // FFI module for the Discord Social SDK, required at runtime. Its native part comes from @koromix/koffi-<platform>
      // in development, and from resources/koffi in the packaged app (extraResources in package.json).
      koffi: 'require("koffi")'
    },
    resolve: {
      aliasFields: [],
      alias: {
        '@': resolve(__dirname, '..', 'common')
      }
    },
    mode,
    target: 'electron39.0-main'
  }
]
