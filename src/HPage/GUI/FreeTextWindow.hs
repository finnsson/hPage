{-# LANGUAGE GeneralizedNewtypeDeriving,
             MultiParamTypeClasses,
             FlexibleInstances,
             FlexibleContexts,
             FunctionalDependencies,
             UndecidableInstances #-}
             
module HPage.GUI.FreeTextWindow ( gui ) where

import Prelude hiding (catch)
import Control.Exception
import Control.Concurrent.MVar
import Control.Concurrent.Process
import System.FilePath
import System.Directory
import System.IO.Error hiding (try, catch)
import Data.List
import Data.Bits
import Data.Char (toLower)
import Data.Version
import Distribution.Package
import Control.Monad.Error
import Control.Monad.Loops
import Graphics.UI.WX
import Graphics.UI.WXCore hiding (kill, Process)
import qualified HPage.Control as HP
import qualified HPage.Server as HPS
import HPage.GUI.Dialogs
import HPage.GUI.IDs
import HPage.GUI.Constants
import HPage.Utils.Log

import Paths_hpage -- cabal locations of data files

imageFile :: FilePath -> IO FilePath
imageFile fp = do
                path <- getDataFileName $ "res/images/" ++ fp
                real <- doesFileExist path
                if real then return path
                        else do
                                errorIO ("file not found", path)
                                fail (path ++ " does not exist")

helpFile :: IO FilePath
helpFile = getDataFileName "res/help/helpPage.hs"

data GUIBottom = GUIBtm { bottomDesc :: String,
                          bottomSource :: String }

data GUIResults = GUIRes { resButton :: Button (),
                           resLabel :: StaticText (),
                           resValue :: TextCtrl (),
                           res4Dots :: StaticText (),
                           resType  :: TextCtrl (),
                           resErrors :: Var [GUIBottom] }

data GUIContext = GUICtx { guiWin :: Frame (),
                           guiPages :: SingleListBox (),
                           guiModules :: (Var Int, ListCtrl ()),
                           guiCode :: TextCtrl (),
                           guiResults :: GUIResults,
                           guiStatus :: StatusField,
                           guiTimer :: Var (TimerEx ()),
                           guiSearch :: FindReplaceData ()} 

gui :: IO ()
gui =
    do
        -- Server context
        model <- HPS.start
        
        win <- frame [text := "\955Page",
                      visible := False]
        imageFile "icon/hpage.tif" >>= topLevelWindowSetIconFromFile win 
        
        set win [on closing := HPS.stop model >> propagateEvent]

        -- Containers
        ntbkL <- notebook win []
        pnlPs <- panel ntbkL []
        pnlMs <- panel ntbkL []
        
        -- Text page...
    --  txtCode <- styledTextCtrl win []
        txtCode <- textCtrl win [font := fontFixed, text := ""]
        
        -- Document Selector
        lstPages <- singleListBox pnlPs [style := wxLB_NEEDED_SB, outerSize := sz 400 600]
        
        -- Modules Lists
        imageFiles <- mapM imageFile ["m_imported.ico", "m_interpreted.ico", "m_compiled.ico", "m_package.ico"]
        imagePaths <- mapM getAbsoluteFilePath imageFiles
        images     <- imageListFromFiles (sz 16 16) imagePaths
        varModsSel <- varCreate $ -1
        lstModules <- listCtrlEx pnlMs (wxLC_REPORT + wxLC_ALIGN_LEFT + wxLC_NO_HEADER + wxLC_SINGLE_SEL)
                                       [columns := [("Module", AlignLeft, 200),
                                                    ("Origin", AlignLeft, 1)]]
        listCtrlSetImageList lstModules images wxIMAGE_LIST_SMALL

        -- Results panel
        pnlRes <- panel win []
        txtValue <- textEntry pnlRes [style := wxTE_READONLY]
        varErrors <- varCreate []
        txtType <- textEntry pnlRes [style := wxTE_READONLY]
        btnInterpret <- button pnlRes [text := "Interpret"]
        lblInterpret <- staticText pnlRes [text := "Value:"]
        lbl4Dots <- staticText pnlRes [text := " :: "]
        set pnlRes [layout := fill $ 
                                row 5 [widget btnInterpret,
                                       centre $ widget lblInterpret,
                                       fill $ widget txtValue,
                                       centre $ widget lbl4Dots,
                                       fill $ widget txtType]]

        -- Status bar...
        status <- statusField [text := "hello... this is \955Page! type in your instructions :)"]
        set win [statusBar := [status]]

        -- Timer ...
        refreshTimer <- timer win [interval := 1000000, on command := debugIO "Inactivity detected"]
        varTimer <- varCreate refreshTimer
        
        -- Search ...
        search <- findReplaceDataCreate wxFR_DOWN
        
        let guiRes = GUIRes btnInterpret lblInterpret txtValue lbl4Dots txtType varErrors
        let guiCtx = GUICtx win lstPages (varModsSel, lstModules) txtCode guiRes status varTimer search 
        let onCmd name acc = traceIO ("onCmd", name) >> acc model guiCtx

        set btnInterpret [on command := onCmd "interpret" interpret]
        
        -- Events
        set lstPages [on select := onCmd "pageChange" pageChange]
        set txtCode [on keyboard := \_ -> onCmd "restartTimer" restartTimer >> propagateEvent,
                     on mouse :=  \e -> case e of
                                            MouseLeftUp _ _ -> onCmd "mouseEvent" restartTimer >> propagateEvent
                                            MouseLeftDClick _ _ -> onCmd "mouseEvent" restartTimer >> propagateEvent
                                            MouseRightDown _ _ -> onCmd "textContextMenu" textContextMenu
                                            _ -> propagateEvent]
        set txtValue [on mouse := \e -> case e of
                                            MouseRightDown _ _ -> onCmd "valueContextMenu" valueContextMenu
                                            _ -> propagateEvent]
        set txtType [on mouse := \e -> case e of
                                            MouseRightDown _ _ -> onCmd "typeContextMenu" typeContextMenu
                                            _ -> propagateEvent]
        set lstModules [on listEvent := \e -> case e of
                                                ListItemSelected idx -> varSet varModsSel idx
                                                ListItemRightClick idx -> varSet varModsSel idx >> onCmd "moduleContextMenu" moduleContextMenu
                                                _ -> propagateEvent]
        
        -- Menu bar...
        mnuPage <- menuPane [text := "Page"]
        menuAppend mnuPage wxId_NEW "&New\tCtrl-n" "New Page" False
        menuAppend mnuPage wxId_CLOSE "&Close\tCtrl-w" "Close Page" False
        menuAppend mnuPage wxId_CLOSE_ALL "&Close All\tCtrl-Shift-w" "Close All Pages" False
        menuAppendSeparator mnuPage
        menuAppend mnuPage wxId_OPEN "&Open...\tCtrl-o" "Open Page" False
        menuAppend mnuPage wxId_SAVE "&Save\tCtrl-s" "Save Page" False
        menuAppend mnuPage wxId_SAVEAS "&Save as...\tCtrl-Shift-s" "Save Page as" False
        menuAppendSeparator mnuPage
        menuQuit mnuPage [on command := wxcAppExit]
        
        mnuEdit <- menuPane [text := "Edit"]
        menuAppend mnuEdit wxId_UNDO "&Undo\tCtrl-z" "Undo" False
        menuAppend mnuEdit wxId_REDO "&Redo\tCtrl-Shift-z" "Redo" False
        menuAppendSeparator mnuEdit
        menuAppend mnuEdit wxId_CUT "C&ut\tCtrl-x" "Cut" False
        menuAppend mnuEdit wxId_COPY "&Copy\tCtrl-c" "Copy" False
        menuAppend mnuEdit wxId_PASTE "&Paste\tCtrl-v" "Paste" False
        menuAppendSeparator mnuEdit
        menuAppend mnuEdit wxId_FIND "&Find...\tCtrl-f" "Find" False
        menuAppend mnuEdit wxId_FORWARD "Find &Next\tCtrl-g" "Find Next" False
        menuAppend mnuEdit wxId_BACKWARD "Find &Previous\tCtrl-Shift-g" "Find Previous" False
        menuAppend mnuEdit wxId_REPLACE "&Replace...\tCtrl-Shift-r" "Replace" False
        menuAppendSeparator mnuEdit
        menuAppend mnuEdit wxId_PREFERENCES "&Preferences...\tCtrl-," "Preferences" False

        mnuHask <- menuPane [text := "Haskell"]
        menuAppend mnuHask wxId_HASK_LOAD_PKG "Load &package...\tCtrl-Alt-l" "Load Cabal Package" False
        menuAppendSeparator mnuHask
        menuAppend mnuHask wxId_HASK_LOAD "&Load modules...\tCtrl-l" "Load Modules" False
        menuAppend mnuHask wxId_HASK_LOADNAME "Load modules by &name...\tCtrl-Shift-l" "Load Modules by Name" False
        menuAppend mnuHask wxId_HASK_ADD "Import modules...\tCtrl-Shift-i" "Import Packaged Modules by Name" False
        menuAppend mnuHask wxId_HASK_RELOAD "&Reload\tCtrl-r" "Reload Modules" False
        menuAppendSeparator mnuHask
        menuAppend mnuHask wxId_HASK_INTERPRET "&Interpret\tCtrl-i" "Interpret the Current Expression" False
        menuAppend mnuHask wxId_HASK_NAVIGATE "Search on Ha&yoo!\tCtrl-y" "Search the Current Selection on Hayoo!" False
        
        mnuHelp <- menuHelp []
        menuAppend mnuHelp wxId_HELP "&Help page\tCtrl-h" "Open the Help Page" False
        menuAbout mnuHelp [on command := infoDialog win "About \955Page" "Author: Fernando Brujo Benavides\nWebsite: http://haskell.hpage.com"]
        
        set win [menuBar := [mnuPage, mnuEdit, mnuHask, mnuHelp]]
        evtHandlerOnMenuCommand win wxId_NEW $ onCmd "runHP' addPage" $ runHP' HP.addPage
        evtHandlerOnMenuCommand win wxId_CLOSE $ onCmd "runHP' closePage" $ runHP' HP.closePage
        evtHandlerOnMenuCommand win wxId_CLOSE_ALL $ onCmd "runHP' closeAllPages" $ runHP' HP.closeAllPages
        evtHandlerOnMenuCommand win wxId_OPEN $ onCmd "openPage" openPage
        evtHandlerOnMenuCommand win wxId_SAVE $ onCmd "savePage" savePage
        evtHandlerOnMenuCommand win wxId_SAVEAS $ onCmd "savePageAs" savePageAs
        evtHandlerOnMenuCommand win wxId_UNDO $ onCmd "runHP' undo" $ runHP' HP.undo
        evtHandlerOnMenuCommand win wxId_REDO $ onCmd "runHP' redo" $ runHP' HP.redo
        evtHandlerOnMenuCommand win wxId_CUT $ onCmd "cut" cut
        evtHandlerOnMenuCommand win wxId_COPY $ onCmd "copy" copy
        evtHandlerOnMenuCommand win wxId_PASTE $ onCmd "paste" paste
        evtHandlerOnMenuCommand win wxId_FIND $ onCmd "justFind" justFind
        evtHandlerOnMenuCommand win wxId_FORWARD $ onCmd "findNext" justFindNext
        evtHandlerOnMenuCommand win wxId_BACKWARD $ onCmd "findPrev" justFindPrev
        evtHandlerOnMenuCommand win wxId_REPLACE $ onCmd "findReplace" findReplace
        evtHandlerOnMenuCommand win wxId_HASK_LOAD_PKG $ onCmd "loadPackage" loadPackage
        evtHandlerOnMenuCommand win wxId_HASK_LOAD $ onCmd "loadModules" loadModules
        evtHandlerOnMenuCommand win wxId_HASK_ADD $ onCmd "importModules" importModules
        evtHandlerOnMenuCommand win wxId_HASK_LOADNAME $ onCmd "loadModulesByName" loadModulesByName
        evtHandlerOnMenuCommand win wxId_HASK_LOAD_FAST $ onCmd "loadModulesByNameFast" loadModulesByNameFast
        evtHandlerOnMenuCommand win wxId_HASK_RELOAD $ onCmd "reloadModules" reloadModules
        evtHandlerOnMenuCommand win wxId_PREFERENCES $ onCmd "preferences" configure
        evtHandlerOnMenuCommand win wxId_HASK_INTERPRET $ onCmd "interpret" interpret
        evtHandlerOnMenuCommand win wxId_HASK_NAVIGATE $ onCmd "hayoo" hayoo
        evtHandlerOnMenuCommand win wxId_HASK_COPY $ onCmd "copyResult" copyResult
        evtHandlerOnMenuCommand win wxId_HASK_COPY_TYPE $ onCmd "copyType" copyType
        evtHandlerOnMenuCommand win wxId_HASK_EXPLAIN $ onCmd "explain" explain
        evtHandlerOnMenuCommand win wxId_HELP $ onCmd "help" openHelpPage
        
        -- Tool bar...
        tbMain <- toolBarEx win True True []
        mitLoadPkg <- menuFindItem mnuHask wxId_HASK_LOAD_PKG
        mitNew <- menuFindItem mnuPage wxId_NEW
        mitOpen <- menuFindItem mnuPage wxId_OPEN
        mitSave <- menuFindItem mnuPage wxId_SAVE
        mitCut <- menuFindItem mnuEdit wxId_CUT
        mitCopy <- menuFindItem mnuEdit wxId_COPY
        mitPaste <- menuFindItem mnuEdit wxId_PASTE
        mitReload <- menuFindItem mnuHask wxId_HASK_RELOAD
        loadPath <- imageFile "load.png"
        newPath <- imageFile "new.png"
        openPath <- imageFile "open.png"
        savePath <- imageFile "save.png"
        cutPath <- imageFile "cut.png"
        copyPath <- imageFile "copy.png"
        pastePath <- imageFile "paste.png"
        reloadPath <- imageFile "reload.png"
        toolMenu tbMain mitLoadPkg "Load Package" loadPath [tooltip := "Load Cabal Package"]
        toolBarAddSeparator tbMain
        toolMenu tbMain mitNew "New" newPath [tooltip := "New Page"]
        toolMenu tbMain mitOpen "Open" openPath [tooltip := "Open Page"]
        toolMenu tbMain mitSave "Save" savePath [tooltip := "Save Page"]
        toolBarAddSeparator tbMain
        toolMenu tbMain mitCut "Cut" cutPath [tooltip := "Cut"]
        toolMenu tbMain mitCopy "Copy" copyPath [tooltip := "Copy"]
        toolMenu tbMain mitPaste "Paste" pastePath [tooltip := "Paste"]
        toolBarAddSeparator tbMain
        toolMenu tbMain mitReload "Reload" reloadPath [tooltip := "Reload Modules"]
        toolBarSetToolBitmapSize tbMain $ sz 32 32

        -- Layout settings
        let pagesTabL   = tab "Pages" $ container pnlPs $ fill $ margin 5 $ widget lstPages
            modsTabL    = tab "Modules" $ container pnlMs $ fill $ margin 5 $ widget lstModules
            leftL       = tabs ntbkL [modsTabL, pagesTabL]
            resultsL    = hfill $ boxed "Expression" $ fill $ widget pnlRes
            rightL      = minsize (sz 485 100) $ fill $ widget txtCode
        set win [layout := column 5 [fill $ row 10 [leftL, rightL], resultsL],
                 clientSize := sz 800 600]
                 
        -- ...and RUN!
        refreshPage model guiCtx
        onCmd "start" openHelpPage
        set win [visible := True]
        focusOn txtCode

-- EVENT HANDLERS --------------------------------------------------------------
refreshPage, savePageAs, savePage, openPage,
    pageChange, copy, copyResult, copyType, cut, paste,
    justFind, justFindNext, justFindPrev, findReplace,
    textContextMenu, moduleContextMenu, valueContextMenu,
    restartTimer, killTimer, interpret, hayoo, explain,
    loadPackage, loadModules, importModules, loadModulesByName, loadModulesByNameFast, reloadModules,
    configure, openHelpPage :: HPS.ServerHandle -> GUIContext -> IO ()

moduleContextMenu model guiCtx@GUICtx{guiWin = win, guiModules = (varModsSel, lstModules)} =
    do
        pointWithinWindow <- windowGetMousePosition win
        i <- varGet varModsSel
        contextMenu <- menuPane []
        case i of
            (-1) ->
                do
                    return ()
            i ->
                do
                    itm <- get lstModules $ item i
                    case itm of
                        [_, "Package"] ->
                            menuAppend contextMenu wxId_HASK_LOAD_FAST "&Load" "Load Module" False
                        [modname, _] ->
                            appendBrowseMenu contextMenu modname
                        other ->
                            menuAppend contextMenu idAny (show other) "Other" False
                    propagateEvent
                    menuPopup contextMenu pointWithinWindow win
                    objectDelete contextMenu
    where appendBrowseMenu contextMenu mn =
            do
                browseMenu <- menuPane []
                hpsRes <- tryIn model $ HP.getModuleExports mn
                case hpsRes of
                    Left err ->
                        menuAppend browseMenu idAny err "Error" False
                    Right mes ->
                        flip mapM_ mes $ createMenuItem browseMenu
                menuItem contextMenu [text := "To Clipboard",
                                      on command := addToClipboard mn]
                menuItem contextMenu [text := "Search on Hayoo!",
                                      on command := hayooDialog win mn]
                menuAppendSeparator contextMenu
                menuAppendSub contextMenu wxId_HASK_BROWSE "&Browse" browseMenu ""
          addToClipboard txt =
            do
                tdo <- textDataObjectCreate txt
                cb <- clipboardCreate
                opened <- clipboardOpen cb
                if opened
                    then do
                        r <- clipboardSetData cb tdo
                        if r
                            then return ()
                            else errorDialog win "Error" "Clipboard operation failed"
                        clipboardClose cb
                    else
                        errorDialog win "Error" "Clipboard not ready"
          createMenuItem m fn@HP.MEFun{HP.funName = fname} =
            do
                itemMenu <- createBasicMenuItem fname
                menuAppendSub m wxId_HASK_MENUELEM (show fn) itemMenu ""
          createMenuItem m HP.MEClass{HP.clsName = cn, HP.clsFuns = []} =
            do
                itemMenu <- createBasicMenuItem cn
                menuAppendSub m wxId_HASK_MENUELEM ("class " ++ cn) itemMenu ""
          createMenuItem m HP.MEClass{HP.clsName = cn, HP.clsFuns = cfs} =
            do
                subMenu <- createBasicMenuItem cn
                menuAppendSeparator subMenu
                flip mapM_ cfs $ createMenuItem subMenu
                menuAppendSub m wxId_HASK_MENUELEM ("class " ++ cn) subMenu ""
          createMenuItem m HP.MEData{HP.datName = dn, HP.datCtors = []} =
            do
                itemMenu <- createBasicMenuItem dn
                menuAppendSub m wxId_HASK_MENUELEM ("data " ++ dn) itemMenu ""
          createMenuItem m HP.MEData{HP.datName = dn, HP.datCtors = dcs} =
            do
                subMenu <- createBasicMenuItem dn
                menuAppendSeparator subMenu
                flip mapM_ dcs $ createMenuItem subMenu
                menuAppendSub m wxId_HASK_MENUELEM ("data " ++ dn) subMenu ""
          createBasicMenuItem name =
            do
                itemMenu <- menuPane []
                menuItem itemMenu [text := "To Clipboard",
                                   on command := addToClipboard name]
                menuItem itemMenu [text := "Search on Hayoo!",
                                   on command := hayooDialog win name]
                return itemMenu


textContextMenu model guiCtx@GUICtx{guiWin = win, guiCode = txtCode} =
    do
        contextMenu <- menuPane []
        sel <- textCtrlGetStringSelection txtCode
        case sel of
                "" ->
                        return ()
                _ ->
                    do
                        menuAppend contextMenu wxId_CUT "C&ut\tCtrl-x" "Cut" False
                        menuAppend contextMenu wxId_COPY "&Copy\tCtrl-c" "Copy" False
                        menuAppend contextMenu wxId_PASTE "&Paste\tCtrl-v" "Paste" False
                        menuAppendSeparator contextMenu
                        menuAppend contextMenu wxId_HASK_NAVIGATE "Search on Ha&yoo!\tCtrl-y" "Search the Current Selection on Hayoo!" False
        menuAppend contextMenu wxId_HASK_INTERPRET "&Interpret\tCtrl-i" "Interpret the Current Expression" False
        propagateEvent
        pointWithinWindow <- windowGetMousePosition win
        menuPopup contextMenu pointWithinWindow win
        objectDelete contextMenu

valueContextMenu model guiCtx@GUICtx{guiWin = win,
                                     guiResults = GUIRes{resValue = txtValue}} =
    do
        contextMenu <- menuPane []
        sel <- textCtrlGetStringSelection txtValue
        case sel of
            "" ->
                return ()
            _ ->
                menuAppend contextMenu wxId_HASK_COPY "Copy" "Copy" False
        if sel == bottomChar || sel == bottomString
            then menuAppend contextMenu wxId_HASK_EXPLAIN "Explain" "Explain" False
            else return ()
        propagateEvent
        pointWithinWindow <- windowGetMousePosition win
        menuPopup contextMenu pointWithinWindow win
        objectDelete contextMenu
        
typeContextMenu model guiCtx@GUICtx{guiWin = win,
                                    guiResults = GUIRes{resType = txtType}} =
    do
        contextMenu <- menuPane []
        sel <- textCtrlGetStringSelection txtType
        case sel of
            "" ->
                do
                    propagateEvent
                    objectDelete contextMenu
            _ ->
                do
                    menuAppend contextMenu wxId_HASK_COPY_TYPE "Copy" "Copy" False
                    propagateEvent
                    pointWithinWindow <- windowGetMousePosition win
                    menuPopup contextMenu pointWithinWindow win
                    objectDelete contextMenu


pageChange model guiCtx@GUICtx{guiPages = lstPages} =
    do
        i <- get lstPages selection
        case i of
            (-1) -> return ()
            _ -> runHP' (HP.setPageIndex i) model guiCtx

openPage model guiCtx@GUICtx{guiWin = win,
                             guiStatus = status} =
    do
        fileNames <- filesOpenDialog win True True "Open file..." [("Haskells",["*.hs"]),
                                                                   ("Any file",["*.*"])] "" ""
        case fileNames of
            [] ->
                return ()
            fs ->
                do
                    set status [text := "opening..."]
                    flip mapM_ fs $ \f -> runHP' (HP.openPage f) model guiCtx

savePageAs model guiCtx@GUICtx{guiWin = win, guiStatus = status} =
    do
        fileName <- fileSaveDialog win True True "Save file..." [("Haskells",["*.hs"]),
                                                                 ("Any file",["*.*"])] "" ""
        case fileName of
            Nothing ->
                return ()
            Just f ->
                do
                    set status [text := "saving..."]
                    runHP' (HP.savePageAs f) model guiCtx

savePage model guiCtx@GUICtx{guiWin = win} =
    do
        maybePath <- tryIn' model HP.getPagePath
        case maybePath of
            Left err ->
                warningDialog win "Error" err
            Right Nothing ->
                savePageAs model guiCtx
            Right _ ->
                do
                    set (guiStatus guiCtx) [text := "saving..."]
                    runHP' HP.savePage model guiCtx

copy _model GUICtx{guiCode = txtCode} = textCtrlCopy txtCode

copyResult _model GUICtx{guiResults = GUIRes{resValue = txtValue}} = textCtrlCopy txtValue

copyType _model GUICtx{guiResults = GUIRes{resType = txtType}} = textCtrlCopy txtType

cut model guiCtx@GUICtx{guiCode = txtCode} = textCtrlCut txtCode >> refreshExpr model guiCtx

paste model guiCtx@GUICtx{guiCode = txtCode} = textCtrlPaste txtCode >> refreshExpr model guiCtx

justFind model guiCtx = openFindDialog model guiCtx "Find..." dialogDefaultStyle

justFindNext model guiCtx@GUICtx{guiSearch = search} =
    do
        curFlags <- findReplaceDataGetFlags search
        findReplaceDataSetFlags search $ curFlags .|. wxFR_DOWN
        findNextButton model guiCtx

justFindPrev model guiCtx@GUICtx{guiSearch = search} =
    do
        curFlags <- findReplaceDataGetFlags search
        findReplaceDataSetFlags search $ curFlags .&. complement wxFR_DOWN
        findNextButton model guiCtx

findReplace model guiCtx = openFindDialog model guiCtx "Find and Replace..." $ dialogDefaultStyle .|. wxFR_REPLACEDIALOG
        
reloadModules = runHP HP.reloadModules

loadPackage model guiCtx@GUICtx{guiWin = win} =
    do
        distExists <- doesDirectoryExist "dist"
        let startDir = if distExists then "dist" else ""
        res <- fileOpenDialog win True True "Select the setup-config file for your project..."
                              [("setup-config",["setup-config"])] startDir "setup-config"
        case res of
                Nothing ->
                    return ()
                Just setupConfig ->
                    do
                        loadres <- tryIn' model $ do
                                                    lr <- HP.loadPackage setupConfig
                                                    HP.addPage
                                                    return lr
                        case loadres of
                            Left err ->
                                warningDialog win "Error" err
                            Right (Left err) ->
                                warningDialog win "Error" err
                            Right (Right pkg) ->
                                do
                                    absPath <- canonicalizePath setupConfig
                                    let dir = joinPath . reverse . drop 2 . reverse $ splitDirectories absPath
                                    setCurrentDirectory dir
                                    frameSetTitle win $ "\955Page - " ++ prettyShow pkg
                        refreshPage model guiCtx
  where prettyShow PackageIdentifier{pkgName = PackageName pkgname,
                                     pkgVersion = pkgvsn} = pkgname ++ "-" ++ showVersion pkgvsn

loadModules model guiCtx@GUICtx{guiWin = win, guiStatus = status} =
    do
        fileNames <- filesOpenDialog win True True "Load Module..." [("Haskell Modules",["*.hs"])] "" ""
        case fileNames of
            [] ->
                return ()
            fs ->
                do
                    set status [text := "loading..."]
                    runHP (HP.loadModules fs) model guiCtx

loadModulesByName model guiCtx@GUICtx{guiWin = win, guiStatus = status} =
    do
        moduleNames <- textDialog win "Enter the module names, separated by spaces" "Load Modules..." ""
        case moduleNames of
            "" ->
                return ()
            mns ->
                do
                    set status [text := "loading..."]
                    runHP (HP.loadModules $ words mns) model guiCtx

loadModulesByNameFast model guiCtx@GUICtx{guiWin = win, guiModules = (varModsSel, lstModules), guiStatus = status} =
    do
        i <- varGet varModsSel
        case i of
            (-1) -> return ()
            i ->
                do
                    mnText <- listCtrlGetItemText lstModules i
                    let mns = [mnText]
                    set status [text := "loading..."]
                    runHP (HP.loadModules mns) model guiCtx

importModules model guiCtx@GUICtx{guiWin = win, guiStatus = status} =
    do
        moduleNames <- textDialog win "Enter the module names, separated by spaces" "Import Packaged Modules..." ""
        case moduleNames of
            "" ->
                return ()
            mns ->
                do
                    set status [text := "loading..."]
                    runHP (HP.importModules $ words mns) model guiCtx

configure model guiCtx@GUICtx{guiWin = win, guiStatus = status} =
    do
        hpsRes <- tryIn model $ do
                                    les <- HP.getLanguageExtensions
                                    sds <- HP.getSourceDirs
                                    gos <- HP.getGhcOpts
                                    case les of
                                        Left e -> return $ Left e
                                        Right l -> return $ Right (l, sds, gos)
        case hpsRes of
            Left err ->
                warningDialog win "Error" err
            Right (les, sds, gos) ->
                do
                    res <- preferencesDialog win "Preferences" $ Prefs les sds gos
                    case res of
                        Nothing ->
                            return ()
                        Just newps ->
                            do
                                set status [text := "setting..."]
                                runHP (do
                                            HP.setLanguageExtensions $ languageExtensions newps
                                            HP.setSourceDirs $ sourceDirs newps
                                            case ghcOptions newps of
                                                "" -> return $ Right ()
                                                newopts -> HP.setGhcOpts newopts
                                            ) model guiCtx

openHelpPage model guiCtx@GUICtx{guiCode = txtCode} =
    do
        f <- helpFile
        txt <- readFile f
        set txtCode [text := txt]
        -- Refresh the current expression box
        refreshExpr model guiCtx

refreshPage model guiCtx@GUICtx{guiWin = win,
                                guiPages = lstPages,
                                guiModules = (varModsSel, lstModules),
                                guiCode = txtCode,
                                guiStatus = status} =
    do
        res <- tryIn' model $ do
                                pc <- HP.getPageCount
                                pages <- mapM HP.getPageNthDesc [0..pc-1]
                                ind <- HP.getPageIndex
                                txt <- HP.getPageText
                                lmsRes <- HP.getLoadedModules
                                ims <- HP.getImportedModules
                                pms <- HP.getPackageModules
                                let lms = case lmsRes of
                                            Left  _ -> []
                                            Right x -> x
                                return (pms, ims, lms, pages, ind, txt)
        case res of
            Left err ->
                warningDialog win "Error" err
            Right (pms, ims, ms, ps, i, t) ->
                do
                    -- Refresh the pages list
                    itemsDelete lstPages
                    (flip mapM) ps $ \pd ->
                                        let prefix = if HP.pIsModified pd
                                                        then "*"
                                                        else ""
                                            name   = case HP.pPath pd of
                                                         Nothing -> "new page"
                                                         Just fn -> takeFileName $ dropExtension fn
                                         in itemAppend lstPages $ prefix ++ name
                    set lstPages [selection := i]
                    
                    -- Refresh the modules lists
                    --NOTE: we know 0 == "imported" / 1 == "interpreted" / 2 == "compiled" / 3 == "package" images
                    --TODO: move that to some kind of constants or so
                    let ims' = map (\m -> (0, [m, "Imported"])) ims
                        ms' = map (\m -> if HP.modInterpreted m
                                            then (1, [HP.modName m, "Interpred"])
                                            else (2, [HP.modName m, "Compiled"])) ms
                        pms' = map (\m -> (3, [m, "Package"])) $
                                        flip filter pms $ \pm -> all (\xm -> HP.modName xm /= pm) ms
                        allms = zip [0..] (ims' ++ ms' ++ pms')
                    itemsDelete lstModules
                    (flip mapM) allms $ \(idx, (img, m@(mn:_))) ->
                                                listCtrlInsertItemWithLabel lstModules idx mn img >>                                                
                                                set lstModules [item idx := m]
                    varSet varModsSel $ -1
                    
                    -- Refresh the current text
                    set txtCode [text := t]
                    
                    -- Clean the status bar
                    set status [text := ""]
                    
                    -- Refresh the current expression box
                    refreshExpr model guiCtx

runHP' ::  HP.HPage () -> HPS.ServerHandle -> GUIContext -> IO ()
runHP' a = runHP $ a >>= return . Right

runHP ::  HP.HPage (Either HP.InterpreterError ()) -> HPS.ServerHandle -> GUIContext -> IO ()
runHP hpacc model guiCtx@GUICtx{guiWin = win} =
    do
        res <- tryIn model hpacc
        case res of
            Left err ->
                warningDialog win "Error" err
            Right () ->
                refreshPage model guiCtx

explain model guiCtx@GUICtx{guiWin = win,
                            guiResults = GUIRes{resValue = txtValue,
                                                resErrors = varErrors}} =
    do
        sel <- textCtrlGetStringSelection txtValue
        if sel == bottomChar || sel == bottomString
            then do
                    txt <- get txtValue text
                    ip <- textCtrlGetInsertionPoint txtValue
                    errs <- varGet varErrors
                    let prevTxt = take ip txt
                        isBottom c = [c] == bottomChar || [c] == bottomString
                        errNo = length $ filter isBottom prevTxt
                        err = if length errs > errNo
                                then bottomDesc $ errs !! errNo
                                else "Unknown"
                    if sel == bottomChar
                        then errorDialog win "Bottom Char" err
                        else errorDialog win "Bottom String" err
            else return ()

hayoo model guiCtx@GUICtx{guiCode = txtCode, guiWin = win} =
    textCtrlGetStringSelection txtCode >>= hayooDialog win

interpret model guiCtx@GUICtx{guiResults = GUIRes{resLabel  = lblInterpret,
                                                  resButton = btnInterpret,
                                                  resValue  = txtValue,
                                                  res4Dots  = lbl4Dots,
                                                  resType   = txtType,
                                                  resErrors = varErrors},
                              guiCode = txtCode, guiWin = win} =
    do
        sel <- textCtrlGetStringSelection txtCode
        let runner = case sel of
                        "" -> tryIn
                        sl -> runTxtHPSelection sl
        refreshExpr model guiCtx
        res <- runner model HP.interpret
        case res of
            Left err ->
                do
                    warningDialog win "Error" err
            Right interp ->
                if HP.isIntType interp
                    then do
                        set txtValue [text := HP.intKind interp]
                        set lbl4Dots [visible := False]
                        set txtType [visible := False]
                        set lblInterpret [text := "Kind:"]
                    else do
                        set lbl4Dots [visible := True]
                        set txtType [visible := True, text := HP.intType interp]
                        set lblInterpret [text := "Value:"]
                        -- now we fill the textbox --
                        varSet varErrors []
                        set txtValue [text := ""]
                        chfHandle <- spawn charFiller
                        chf <- varCreate chfHandle
                        spawn . valueFiller chf $ HP.intValue interp
                        return ()
    where valueFiller :: Var (Handle (String, MVar ())) -> String -> Process a ()
          valueFiller chf val =
              do
                    prevOnCmd <- liftIO $ get btnInterpret $ on command
                    myself <- self
                    let revert = set btnInterpret [on command := prevOnCmd,
                                                   text := "Interpret"]
                    liftIO $ set btnInterpret [text := "Cancel",
                                               on command := do
                                                                spawn $ liftIO revert >> kill myself
                                                                return ()]
                    h <- liftIO $ try (case val of
                                            [] -> return []
                                            (c:_) -> return [c])
                    case h of
                        Left (ErrorCall desc) ->
                            liftIO $ do
                                        varUpdate varErrors (++ [GUIBtm desc val])
                                        addText bottomString
                                        revert
                        Right [] ->
                            liftIO revert
                        Right t ->
                            do
                                chfHandle <- liftIO $ varGet chf
                                ready <- liftIO $ newEmptyMVar
                                let killCmd =
                                            do
                                                stillRunning <- liftIO $ isEmptyMVar ready
                                                if stillRunning
                                                    then do
                                                        kill chfHandle
                                                        chfNewHandle <- liftIO . spawn $ charFiller
                                                        varSet chf chfNewHandle
                                                        varUpdate varErrors (++ [GUIBtm "Timed Out" t])
                                                        addText bottomChar
                                                        return ()
                                                    else
                                                        return ()
                                sendTo chfHandle (t, ready)
                                timeKiller <- liftIO $ timer win [interval := charTimeout,
                                                                  on command := killCmd]
                                liftIO $ takeMVar ready
                                liftIO $ timerOnCommand timeKiller $ return ()
                                valueFiller chf $ tail val
          charFiller :: Process (String, MVar ()) ()
          charFiller = forever $ do
                            (t, r) <- recv
                            liftIO $ do
                                        catch (addText t) $ \(ErrorCall desc) ->
                                                                    varUpdate varErrors (++ [GUIBtm desc t]) >>
                                                                    addText bottomChar
                                        putMVar r ()
          addText = textCtrlAppendText txtValue
 
runTxtHPSelection :: String ->  HPS.ServerHandle ->
                     HP.HPage (Either HP.InterpreterError HP.Interpretation) -> IO (Either ErrorString HP.Interpretation)
runTxtHPSelection s model hpacc =
    do
        piRes <- tryIn' model HP.getPageIndex
        added <- tryIn' model $ HP.addPage
        case added of
                Left err ->
                    return $ Left err
                Right () ->
                    do
                        let cpi = case piRes of
                                        Left err -> 0
                                        Right cp -> cp
                            newacc = HP.setPageText s (length s) >> hpacc
                        res <- tryIn model newacc
                        tryIn' model $ HP.closePage >> HP.setPageIndex cpi 
                        return res

refreshExpr :: HPS.ServerHandle -> GUIContext -> IO ()
refreshExpr model guiCtx@GUICtx{guiCode = txtCode,
                                guiWin = win} =
   do
        txt <- get txtCode text
        ip <- textCtrlGetInsertionPoint txtCode
        
        res <- tryIn' model $ HP.setPageText txt ip
        
        case res of
            Left err ->
                warningDialog win "Error" err
            Right _ ->
                debugIO "refreshExpr done"
        
        killTimer model guiCtx


-- TIMER HANDLERS --------------------------------------------------------------
restartTimer model guiCtx@GUICtx{guiWin = win, guiTimer = varTimer} =
    do
        newRefreshTimer <- timer win [interval := 1000,
                                      on command := refreshExpr model guiCtx]
        refreshTimer <- varSwap varTimer newRefreshTimer
        timerOnCommand refreshTimer $ return ()

killTimer _model GUICtx{guiWin = win, guiTimer = varTimer} =
    do
        -- kill the timer till there's new notices
        newRefreshTimer <- timer win [interval := 1000000, on command := debugIO "Inactivity detected"]
        refreshTimer <- varSwap varTimer newRefreshTimer
        timerOnCommand refreshTimer $ return ()

-- INTERNAL UTILS --------------------------------------------------------------
type ErrorString = String

tryIn' :: HPS.ServerHandle -> HP.HPage x -> IO (Either ErrorString x)
tryIn' model hpacc = tryIn model $ hpacc >>= return . Right

tryIn :: HPS.ServerHandle -> HP.HPage (Either HP.InterpreterError x) -> IO (Either ErrorString x)
tryIn model hpacc =
    do
        res <- HPS.runIn model $ catchError (hpacc >>= return . Right)
                                            (\ioerr -> return $ Left ioerr)
        case res of
            Left err          -> return . Left  $ ioeGetErrorString err
            Right (Left err)  -> return . Left  $ HP.prettyPrintError err
            Right (Right val) -> return . Right $ val

-- FIND/REPLACE UTILS ----------------------------------------------------------
data FRFlags = FRFlags {frfGoingDown :: Bool,
                        frfMatchCase :: Bool,
                        frfWholeWord :: Bool,
                        frfWrapSearch :: Bool}
    deriving (Eq, Show)

buildFRFlags :: Bool -> Int -> IO FRFlags
buildFRFlags w x = return FRFlags {frfGoingDown = (x .&. wxFR_DOWN) /= 0,
                                   frfMatchCase = (x .&. wxFR_MATCHCASE) /= 0,
                                   frfWholeWord = (x .&. wxFR_WHOLEWORD) /= 0,
                                   frfWrapSearch = w}

openFindDialog :: HPS.ServerHandle -> GUIContext -> String -> Int -> IO ()
openFindDialog model guiCtx@GUICtx{guiWin = win,
                                   guiSearch = search} title dlgStyle =
    do
        frdialog <- findReplaceDialogCreate win search title $ dlgStyle + wxFR_NOWHOLEWORD
        let winSet k f = let hnd _ = f model guiCtx >> propagateEvent
                          in windowOnEvent frdialog [k] hnd hnd
        winSet wxEVT_COMMAND_FIND findNextButton
        winSet wxEVT_COMMAND_FIND_NEXT findNextButton
        winSet wxEVT_COMMAND_FIND_REPLACE findReplaceButton
        winSet wxEVT_COMMAND_FIND_REPLACE_ALL findReplaceAllButton
        set frdialog [visible := True]

findNextButton, findReplaceButton, findReplaceAllButton :: HPS.ServerHandle -> GUIContext -> IO ()
findNextButton model guiCtx@GUICtx{guiCode = txtCode,
                                   guiWin = win,
                                   guiSearch = search} =
    do
        s <- findReplaceDataGetFindString search
        fs <- findReplaceDataGetFlags search >>= buildFRFlags True
        mip <- findMatch s fs txtCode
        debugIO ("find/next", s, fs, mip)
        case mip of
            Nothing ->
                infoDialog win "Find Results" $ s ++ " not found."
            Just ip ->
                do
                    textCtrlSetSelection txtCode (length s + ip) ip
                    refreshExpr model guiCtx 

findReplaceButton model guiCtx@GUICtx{guiCode = txtCode,
                                      guiWin = win,
                                      guiSearch = search} =
    do
        s <- findReplaceDataGetFindString search
        r <- findReplaceDataGetReplaceString search
        fs <- findReplaceDataGetFlags search >>= buildFRFlags True
        mip <- findMatch s fs txtCode
        debugIO ("replace", s, r, fs, mip)
        case mip of
            Nothing ->
                infoDialog win "Find Results" $ s ++ " not found."
            Just ip ->
                do
                    textCtrlReplace txtCode ip (length s + ip) r
                    textCtrlSetSelection txtCode (length r + ip) ip
                    refreshExpr model guiCtx
        
findReplaceAllButton _model GUICtx{guiCode = txtCode,
                                   guiSearch = search} =
    do
        s <- findReplaceDataGetFindString search
        r <- findReplaceDataGetReplaceString search        
        fs <- findReplaceDataGetFlags search >>= buildFRFlags False
        debugIO ("all", s, r, fs)
        textCtrlSetInsertionPoint txtCode 0
        unfoldM_ $ do
                        mip <- findMatch s fs txtCode
                        case mip of
                            Nothing ->
                                return mip
                            Just ip ->
                                do
                                    textCtrlReplace txtCode ip (length s + ip) r
                                    textCtrlSetInsertionPoint txtCode $ length r + ip
                                    return mip
        
findMatch :: String -> FRFlags -> TextCtrl () -> IO (Maybe Int)
findMatch query flags txtCode =
    do
        txt <- get txtCode text
        ip <- textCtrlGetInsertionPoint txtCode
        let (substring, string) = if frfMatchCase flags
                                    then (query, txt)
                                    else (map toLower query, map toLower txt)
            funct = if frfGoingDown flags
                        then nextMatch (ip + 1)
                        else prevMatch ip
            (mip, wrapped) = funct substring string
        return $ if (not $ frfWrapSearch flags) && wrapped
                    then Nothing
                    else mip
        

prevMatch, nextMatch :: Int -> String -> String -> (Maybe Int, Bool)
prevMatch _ [] _ = (Nothing, True) -- When looking for nothing, that's what you get
prevMatch from substring string | length string < from || from <= 0 = prevMatch (length string) substring string
                                | otherwise =
                                        case nextMatch (fromBack from) (reverse substring) (reverse string) of
                                            (Nothing, wrapped) -> (Nothing, wrapped)
                                            (Just ri, wrapped) -> (Just $ fromBack (ri + length substring), wrapped)
    where fromBack x = length string - x

nextMatch _ [] _ = (Nothing, True) -- When looking for nothing, that's what you get
nextMatch from substring string | length substring > length string = (Nothing, True)
                                | length string <= from = nextMatch 0 substring string
                                | otherwise =
                                        let after = drop from string
                                            before = take (from + length substring) string
                                            aIndex = indexOf substring after
                                            bIndex = indexOf substring before
                                         in case aIndex of
                                                Just ai ->
                                                    (Just $ from + ai,  False)
                                                Nothing ->
                                                    case bIndex of
                                                        Nothing -> (Nothing, True)
                                                        Just bi -> (Just bi, True)
    
indexOf :: String -> String -> Maybe Int
indexOf substring string = findIndex (isPrefixOf substring) $ tails string
