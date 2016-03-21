import nimx.naketools

beforeBuild = proc(b: Builder) =
    b.mainFile = "minecraft"
    #b.disableClosureCompiler = true
