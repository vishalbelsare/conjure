import os, jester, typetraits, sequtils, tables, db_sqlite, types, parseutils,
        strutils, json, strformat, sequtils, sugar

import jsonify
import init
import process
import branchingCondition


var dBTable: Table[string, DBconn]

proc loadAncestors*(dirPath, nodeId: string): seq[Node]

proc init*(dirPath: string): (Core, string) =
    ## Initialises data structures
    var eprimeInfoFilePath: string
    var db: DbConn
    (db, eprimeInfoFilePath) = findFiles(dirPath)
    dBTable[dirPath] = db

    writePaths(db)
    let infoFile = readFile(eprimeInfoFilePath)
    return (makeCore(db), infoFile)


proc checkDomainsAreEqual*(paths: array[2, string], nodeIds: array[2,
        string]): bool =
    # let query1 = "select group_concat(name, storeDump) from domain where nodeId = ? and name not like 'aux%'"
    let query1 = "select group_concat(name || ' - ' || storeDump, ' , ') from Domain where nodeId = ? and name not like 'aux%'"
    let leftDB = dBTable[paths[0]]
    let rightDB = dBTable[paths[1]]

    var leftValue = leftDB.getValue(sql(query1), nodeIds[0])

    var rightValue = rightDB.getValue(sql(query1), nodeIds[1])

    return leftValue == rightValue


proc nodeIdsToArray(current, other: int, leftIsMore: bool): array[2, int] =
    if leftIsMore:
        return [current, other]
    return [other, current]

proc atEndOfTree*(notFinishedTreePath: string, finishedTreeLastId: int): seq[int] =
    let ancestors = loadAncestors(notFinishedTreePath, $finishedTreeLastId)
    let augmentedIds = ancestors.filter(x => x.id > finishedTreeLastId).map(x => x.id)
    return augmentedIds

proc getAugs*(leftPath, rightPath: string,
                    diffLocations: seq[seq[int]]): seq[seq[int]] =

    result = newSeq[seq[int]](2)

    for i in countUp(0, 1):

        let diffIds = diffLocations.map(x => x[i])

        for loc in diffLocations:
            # if (loc[0] == 227):

            var path = leftPath
            var db = dBTable[leftPath]

            if (i == 1):
                path = rightPath
                db = dBTable[rightPath]

            let nodePath = db.getValue(sql(
                    fmt"select path from Node where nodeId = {loc[i]}"))

            let query = fmt"""
            select nodeId as n from  

                ( select nodeId, path from Node where  
                    nodeId > {loc[i]} and parentId != {loc[i]} and (
                    
                    ( nodeId in
                        (WITH split(word, str) AS (
                                    SELECT '', '{nodePath}' ||'/'
                                    UNION ALL SELECT
                                    substr(str, 0, instr(str, '/')),
                                    substr(str, instr(str, '/')+1)
                                    FROM split WHERE str!=''
                                ) SELECT word FROM split WHERE word!=''
                        ) 
                    )

                    or
                        
                    ( parentId in
                        (WITH split(word, str) AS (
                                    SELECT '', '{nodePath}' ||'/'
                                    UNION ALL SELECT
                                    substr(str, 0, instr(str, '/')),
                                    substr(str, instr(str, '/')+1)
                                    FROM split WHERE str!=''
                                ) SELECT word FROM split WHERE word!=''
                        ) 
                    )
                )
            )
            where not exists
            (
            select nodeId, path from Node where path like '%/' || n || '/%' 
            and nodeId in ({($diffIds)[2..^2]}) 
            )
            """

            var id: int
            for row in db.fastRows(sql(query)):
                discard row[0].parseInt(id)
                if not result[i].contains(id):
                    result[i].add(id)




# type DiffResponse* = ref object of RootObj
#     diffLocations*: seq[seq[int]]
#     augmentedIds*: seq[seq[int]]

type DiffPoint* = ref object of RootObj
    leftTreeId*: int
    rightTreeId*: int
    highlightLeft*: seq[int]
    highlightRight*: seq[int]

proc newDiffPoint(l, r: string, highlightLeft, highlightRight: seq[
        string]): DiffPoint =

    var lNum, rNum: int
    discard l.parseInt(lNum)
    discard r.parseInt(rNum)

    let hL = highlightLeft.map(
        proc (x: string): int =
        var num: int
        discard x.parseInt(num)
        return num
        )

    let hR = highlightRight.map(
        proc (x: string): int =
        var num: int
        discard x.parseInt(num)
        return num
        )

    return DiffPoint(leftTreeId: lNum, rightTreeId: rNum, highlightLeft: hL,
            highlightRight: hR)

proc `$`*(d: DiffPoint): string =
    result = fmt"<({d.leftTreeId}, {d.rightTreeId}) {d.highlightLeft} {d.highlightRight}>"

proc findDiffLocationsBoyo*(leftPath, rightPath: string,
        debug: bool = false): seq[DiffPoint] =

#Concept of the diff point is wrong, what we need is a way of keeping track of different branches

    let leftDB = dBTable[leftPath]
    let rightDB = dBTable[rightPath]
    let dbs = [leftDB, rightDb]

    let kidsQuery = "select nodeId from Node where parentId = ?"

    # var diffPoints = newSeq[seq[string]]()
    var tuples = newSeq[(string, string)]()
    var diffPoints = newSeq[DiffPoint]()

    proc recursive(ids: array[2, string], prevIds: array[2, string]) =

        echo fmt"Current ", ids
        echo checkDomainsAreEqual([leftPath, rightPath], ids)

        if not checkDomainsAreEqual([leftPath, rightPath], ids):

            let t = (prevIds[0], prevIds[1])
            if tuples.contains(t):
                return

            var kids: array[2, seq[string]]

            for i in countUp(0, 1):
                for row in dbs[i].fastRows(sql(kidsQuery), prevIds[i]):
                    kids[i].add(row[0])
            let diffPoint = newDiffPoint(prevIds[0], prevIds[1], kids[0], kids[1])
            diffPoints.add(diffPoint)
            tuples.add((prevIds[0], prevIds[1]))
            echo "HERRRRE"
            return

        var grandKids: array[2, seq[string]]

        for i in countUp(0, 1):
            for row in dbs[i].fastRows(sql(kidsQuery), ids[i]):
                grandKids[i].add(row[0])

        let maxGrandKids = grandKids.map(x => x.len()).max() - 1

        # var numOfKidsIsDifferent = false

        # for i in countUp(0, maxGrandKids):
        #     for j in countUp(0, 1):
        #         if grandKids[j].len() - 1 < i:
        #             numOfKidsIsDifferent = true


        # if numOfKidsIsDifferent:
        #     echo "@ ", ids, "                      grandkids0: ", grandKids[0], "   kids1: ", grandKids[1]

        #     let diffPoint = newDiffPoint(ids[0], ids[1], grandKids[0], grandKids[1])
        #     diffPoints.add(diffPoint)
        # else:

        for i in countUp(0, maxGrandKids):
            # echo fmt"Recursing on {i}", [grandKids[0][i], grandKids[1][i]]
            var nextLeft: string
            var nextRight: string

            if i >= grandKids[0].len():
                nextLeft = ids[0]
            else:
                nextLeft = grandKids[0][i]

            if i >= grandKids[1].len():
                nextRight = ids[1]
            else:
                nextRight = grandKids[1][i]

            recursive([nextLeft, nextRight], ids)




    recursive(["0", "0"], ["-1", "-1"])

    # echo diffPoints
    return diffPoints

    # return res

    # return res.map(x => @[x[0], x[1]])

    # let query = "select nodeId, parentId from Node;"
    # var id2Childrens = [initTable[string, (string, string)](), initTable[string, (string, string)]()]

    # for i in countUp(0, 1):

    #     let db = dbs[i]
    #     # var nodeId, parentId: int

    #     echo "Loading Node Table"

    #     for res in db.fastRows(sql(query)):

    #         let nodeId = res[0]
    #         let parentId = res[1]

    #         if (not id2Childrens[i].haskey(parentId)):
    #             id2Childrens[i][parentId] = ("-1", "-1")

    #         let (kid1, kid2) = id2Childrens[i][parentId]

    #         if kid1 == "-1":
    #             id2Childrens[i][parentId] = ($nodeId, "-1")
    #         else:
    #             id2Childrens[i][parentId] = (kid1, $nodeId)

    #     echo "Calculating Node Paths"






# proc findDiffLocations*(leftPath, rightPath: string, debug: bool = false): seq[
#         seq[int]] =


    # return findDiffLocationsBoyo(leftPath, rightPath).map(proc(x: seq[
    #         string]): seq[int] =
    #     var leftNum: int
    #     var rightNum: int
    #     discard x[0].parseInt(leftNum)
    #     discard x[1].parseInt(rightNum)

    #     @[leftNum, rightNum]
    # )

    # var res: seq[(int, int)]

    # let leftDB = dBTable[leftPath]
    # let rightDB = dBTable[rightPath]

    # let dbs = [leftDB, rightDb]

    # let query = "select count(nodeId) from Node"

    # var lCount: int
    # var rCount: int

    # discard leftDB.getValue(sql(query)).parseInt(lCount)
    # discard rightDB.getValue(sql(query)).parseInt(rCount)

    # var lIsMore = lCount >= rCount

    # var nodeIds = [0, 0]
    # var current: int
    # var other: int
    # var db: DbConn

    # if not checkDomainsAreEqual([leftPath, rightPath], nodeIds):
    #     return @[@[-1, -1]]

    # while true:

    #     if debug:
    #         echo ""
    #         echo nodeIds[0], "     ", nodeIds[1]

    #     # Increment each tree until we get to a point where they differ

    #     loopWhileEqual([leftPath, rightPath], nodeIds, lCount, rCount)

    #     let leftIsFinished = nodeIds[0] >= lCount
    #     let rightIsFinished = nodeIds[1] >= rCount

    #     # If we get to the end of one of the trees then we've finished and need to return
    #     if (leftIsFinished or rightIsFinished):
    #         if debug:
    #             echo nodeIds[0], "     ", nodeIds[1]
    #             echo "quiting"

    #         if res.len() > 0 or not (lCount == rCount):
    #             res.add((nodeIds[0] - 1, nodeIds[1] - 1))

    #         return res.map(s => @[s[0], s[1]])


    #     if debug:
    #         echo nodeIds[0], "     ", nodeIds[1]

    #     nodeIds[0].dec()
    #     nodeIds[1].dec()

    #     if debug:
    #         echo nodeIds[0], "     ", nodeIds[1]

    #     # Add the first firr point to the res
    #     res.add((nodeIds[0], nodeIds[1]))

    #     # set the currentId to the last node in the subtree that just got added, for both trees

    #     var advanceBothTrees = true

    #     # Advance both trees to the next branch that is not descended from the last findDiffLocations point
    #     while advanceBothTrees:
    #         var couldParse = 1

    #         for index, db in dbs:

    #             let path = db.getValue(sql"select path from Node where nodeId = ?",
    #                     nodeIds[index])
    #             var nextId: int
    #             let query = fmt"select nodeId from Node where path not like '{path}%' and nodeId > {nodeIds[index]} limit 1"
    #             couldParse = db.getValue(sql(query)).parseInt(nextId)

    #             if couldParse == 0:
    #                 if debug:
    #                     echo "quitting 2"
    #                     echo index, " | ", query
    #                 let diffLocations = res.map(s => @[s[0], s[1]])
    #                 return diffLocations


    #             nodeIds[index] = nextId

    #         if debug:
    #             echo "Advanced both trees to:"
    #             echo nodeIds[0], "     ", nodeIds[1]

    #         # Initialise the variables such that they refer to the largest tree

    #         if lIsMore:
    #             current = nodeIds[0]
    #             other = nodeIds[1]
    #             db = leftDB
    #         else:
    #             current = nodeIds[1]
    #             other = nodeIds[0]
    #             db = rightDB

    #         #  Go through all the subsequent branches of the tree with the most nodes to see if there
    #         # is a node equal to that of the smaller tree
    #         # while lRes[nodeIds[0]] != rRes[nodeIds[1]] and couldParse != 0:

    #         while not checkDomainsAreEqual([leftPath, rightPath],
    #                 nodeIdsToArray(current, other, lIsMore)):

    #             if debug:
    #                 echo "start of botoom loop"
    #                 echo fmt"current: {current}, other: {other}"

    #             let path = db.getValue(sql"select path from Node where nodeId = ?", current)

    #             var nextId: int

    #             let query = fmt"select nodeId from Node where path not like '{path}%' and nodeId > {current} limit 1"

    #             couldParse = db.getValue(sql(query)).parseInt(nextId)

    #             if couldParse == 0:
    #                 break

    #             current = nextId

    #         if couldParse != 0:
    #             nodeIds = nodeIdsToArray(current, other, lIsMore)
    #             advanceBothTrees = false

    #         if debug:
    #             echo "end of bottom loop: "
    #             echo nodeIds[0], "     ", nodeIds[1]



    #     if (res.contains((567, 146))):
    #         return res.map(s =>x[ @[s[0], s[1]])

    # if debug:
    #     echo "end"

    # let diffLocations = res.map(s => @[s[0], s[1]])
    # return diffLocations


proc diff*(leftPath, rightPath: string, debug: bool = false): seq[DiffPoint] =
    # let diffLocations = findDiffLocations(leftPath, rightPath, debug)
    # let augs = newSeq[seq[int]](2)
    # let augs = getAugs(leftPath, rightPath, diffLocations)
    # return DiffResponse(diffLocations: diffLocations, augmentedIds: augs)
    return findDiffLocationsBoyo(leftPath, rightPath)

proc diffHandler*(leftPath, rightPath, leftHash, rightHash: string): JsonNode =
    # let diffCachesDir = fmt"{parentDir(leftPath)}/diffCaches"
    # let diffCacheFile = fmt"{diffCachesDir}/{leftHash}~{rightHash}.json"
    # let flipped = fmt"{diffCachesDir}/{rightHash}~{leftHash}.json"

    # if fileExists(diffCacheFile):
    #     return parseJson(readAll(open(diffCacheFile)))

    # if fileExists(flipped):
    #     var contents = parseJson(readAll(open(flipped)))
    #     return %contents["diffLocations"]
    #         .getElems()
    #         .map(x => [x[1], x[0]])


    let res = diff(leftPath, rightPath)
    # writeFile(diffCacheFile, $(%res))
    return %res

proc loadAncestors*(dirPath, nodeId: string): seq[Node] =
    ## Loads the children of a node
    let db = dBTable[dirPath]

    var nId: int
    discard nodeId.parseInt(nId)

    let path = db.getValue(sql"select path from Node where nodeId = ?", nodeId)

    let query = fmt"""
    select nodeId, parentId, branchingVariable, isLeftChild, value, isSolution from Node where 
    ( nodeId in
        (WITH split(word, str) AS (
                    SELECT '', '{path}' ||'/'
                    UNION ALL SELECT
                    substr(str, 0, instr(str, '/')),
                    substr(str, instr(str, '/')+1)
                    FROM split WHERE str!=''
                ) SELECT word FROM split WHERE word!=''
        ) 
    )

    or
        
    ( parentId in
        (WITH split(word, str) AS (
                    SELECT '', '{path}' ||'/'
                    UNION ALL SELECT
                    substr(str, 0, instr(str, '/')),
                    substr(str, instr(str, '/')+1)
                    FROM split WHERE str!=''
                ) SELECT word FROM split WHERE word!=''
        ) 
    )
         """

    discard processQuery(db, sql(query), result)





proc loadNodes*(dirPath, nodeId, depth: string): seq[Node] =
    ## Loads the children of a node
    # echo "path ", dirPath
    # echo "nodeId", nodeId
    # echo "depth", depth

    let db = dBTable[dirPath]

    var limit: int
    discard depth.parseInt(limit)
    # limit += 1

    var nId: int
    discard nodeId.parseInt(nId)

    let path = db.getValue(sql"select path from Node where nodeId = ?", nodeId)

    let query = "select nodeId, parentId, branchingVariable, isLeftChild, value, isSolution, path as p from Node where path like '" &
        path & """%' and (select count(*) from
        (WITH split(word, str) AS (
                    SELECT '', p ||'/'
                    UNION ALL SELECT
                    substr(str, 0, instr(str, '/')),
                    substr(str, instr(str, '/')+1)
                    FROM split WHERE str!=''
                ) SELECT word FROM split WHERE word!=''
        ) ) <= """ & $(path.split("/").len() + limit) & " and nodeId != " &
                nodeId & " order by length(p)"

    discard processQuery(db, sql(query), result)

proc loadSimpleDomains*(dirPath, nodeId: string,
        wantExpressions: bool = false): SimpleDomainResponse =
    ## Returns the simple domains for a given node

    let db = dBTable[dirPath]

    var list: seq[string]
    var id: int
    var domainsAtPrev: seq[Variable]
    discard parseInt(nodeId, id)

    let domainsAtNode = getSimpleDomainsOfNode(db, nodeId, wantExpressions)

    if (id != rootNodeId):
        domainsAtPrev = getSimpleDomainsOfNode(db, $(id - 1), wantExpressions)

        for i in 0..<domainsAtNode.len():
            if (domainsAtNode[i].rng != domainsAtPrev[i].rng):
                list.add(domainsAtNode[i].name)

    return SimpleDomainResponse(changedNames: list, vars: domainsAtNode)
