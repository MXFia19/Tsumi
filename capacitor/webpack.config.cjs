const commonConfig = require('common/webpack.config.cjs')
const { merge } = require('webpack-merge')
const { join, resolve } = require('path')

const alias = {
  '@/modules/support.js': join(__dirname, 'src', 'main', 'support.js'),
  '@': resolve(__dirname, '..', 'common')
}

/** @type {import('webpack').Configuration} */
const devServerConfig = {
  devServer: {
    devMiddleware: {
      writeToDisk: true
    },
    hot: true,
    client: {
      overlay: { errors: true, warnings: false, runtimeErrors: false }
    },
    port: 5001
  }
}

module.exports = [merge({ entry: [join(__dirname, 'src', 'main', 'main.js')] }, commonConfig(__dirname, alias, 'browser', 'index'), devServerConfig)]
