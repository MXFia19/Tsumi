# Modules natifs précompilés

`PaymoWinShutdownHandler.node` vient de `@paymoapp/electron-shutdown-handler@1.1.2`,
tel qu'il était livré dans Tsumi 1.2.0 (Electron 39.2.7). C'est un module N-API :
il fonctionne sans recompilation avec les autres versions d'Electron.

Il évite d'avoir besoin de Visual Studio (node-gyp) pour installer les dépendances :
le paquet n'est donc pas listé dans `pnpm.onlyBuiltDependencies`, et le fichier est
copié dans `node_modules` après `pnpm install` (voir `.github/workflows/main.yml`).
