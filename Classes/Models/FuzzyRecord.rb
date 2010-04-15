# FuzzyRecord.rb
# FuzzyWindow
#
# Created by Geoffrey Grosenbach on 3/16/10.
# Copyright 2010 Topfunky Corporation. All rights reserved.

class FuzzyRecord

  attr_accessor *[:projectRoot,
                  :filePath, :filePaths,
                  :scmStatus, :scmName,
                  :codeObjectName, :codeObjectNames,
                  :matchedRanges, :matchesOnFilenameScore]

  MAX_SCORE = 10_000

  def self.recordsWithProjectRoot(theProjectRoot)
    cacheScmStatus(theProjectRoot)
    return loadRecordsWithProjectRoot(theProjectRoot)
  end

  def self.cacheScmStatus(theProjectRoot)
    # TODO: Run async
    #
    # Run "git diff --numstat" on projectRoot and save for all
    # in an NSDictionary
    #
    # 3       1       Tests/run_suite.rb
    # -       -       Foo/Bar.rb
    @@scmStatusDictionary = {}
    projectDotGitPath =
      NSString.pathWithComponents([theProjectRoot, ".git"])
    unless NSFileManager.defaultManager.fileExistsAtPath(projectDotGitPath)
      return
    end
    if output = `cd #{theProjectRoot} && git diff --numstat`
      output.split(/\n/).each do |outputLine|
        added, deleted, filePath = outputLine.split
        @@scmStatusDictionary[filePath] = [added.to_i, deleted.to_i]
      end
    end
  end

  ##
  # NOTE: NSPredicate
  #     p = NSPredicate.predicateWithFormat("name = 'john'")
  #     p.evaluateWithObject({"name" => "bert"}) # => false

  def self.loadRecordsWithProjectRoot(theProjectRoot)
    maximumDocumentCount =
      NSUserDefaults.standardUserDefaults.integerForKey("maximumDocumentCount")
    if maximumDocumentCount == 0
      # HACK: Tests don't have user defaults, so force one here
      maximumDocumentCount =
        AppDelegate.registrationDefaults["maximumDocumentCount"]
    end
    records = []
    fileManager = NSFileManager.defaultManager
    filenames = fileManager.contentsOfDirectoryAtPath(theProjectRoot,
                                                      error:nil).map {|f|
      theProjectRoot.stringByAppendingPathComponent(f)
    }
    index = 0
    while (index < filenames.length && records.length < maximumDocumentCount) do
      filename = filenames[index]
      index += 1
      next if NSWorkspace.sharedWorkspace.isFilePackageAtPath(filename)
      relativeFilename = filename.to_s.gsub(/^#{theProjectRoot}\//, '')
      # TODO: Store ignorable directories, files in preferences
      ignorePatterns = /^(\.git|\.hg|\.svn|build|tmp|log|vendor\/(rails|gems|plugins))\b/i
      next if relativeFilename.match(ignorePatterns)
      next if relativeFilename.match(/(\.DS_Store|\.png|\.jpe?g|\.gif|\.elc|\.swp|~)$/)
      if File.directory?(filename)
        # TODO: Should ignore dot directories
        fileManager.contentsOfDirectoryAtPath(filename,
                                              error:nil).map {|f|
          filenames << filename.stringByAppendingPathComponent(f)
        }
        next
      end
      records << FuzzyRecord.alloc.initWithProjectRoot(theProjectRoot,
                                                       filePath:relativeFilename)
    end
    records
  end

  def self.filterRecords(records, forString:searchString)
    correctedSearchString = searchString.gsub(" ", "")
    records.select { |r|
      r.fuzzyInclude?(correctedSearchString)
    }.sort_by { |record| [ -record.matchesOnFilenameScore,
                           -record.longestMatch,
                           record.matchScore,
                           -record.modifiedAt.timeIntervalSince1970 ] }
  end

  def self.resetMatchesForRecords!(records)
    # NOTE: parallel_map is possible, but may not be any faster
    #       unless records array is large. And it causes SIGSEGV.
    records.map {|r| r.resetMatches! }
  end

  def initWithProjectRoot(theProjectRoot, filePath:theFilePath)
    @projectRoot = theProjectRoot
    @filePath = theFilePath
    @matchedRanges = []
    self
  end

  ##
  # Finds "a/b/c" in "armadillo/bacon/cheshire"
  #
  # Returns true if the string matches this record.
  #
  # Populates @matchedRanges with an Array of NSRange objects
  # identifying the matches.

  def fuzzyInclude?(searchString)
    resetMatches!
    # TODO: Search other things like date, classes, or SCM status
    # Multiple strategies: filename, first occurrence, most
    # contiguous.
    filename = File.basename(filePath)
    if filenameMatchRanges = searchText(filename,
                                        forFirstOccurrenceOfString:searchString)
      @matchesOnFilenameScore = 1
      @matchScore = calculateMatchScoreForRanges(filenameMatchRanges)
      dirname = File.dirname(filePath)
      if dirname == "."
        @matchedRanges = filenameMatchRanges
      else
        @matchedRanges = offsetRanges(filenameMatchRanges, by:dirname.length)
      end
      return true

    elsif firstOccurrenceMatches = searchText(filePath,
                                              forFirstOccurrenceOfString:searchString)
      if reverseSearchMatches = searchInReverseForString(searchString)
        if calculateMatchScoreForRanges(reverseSearchMatches) <
            calculateMatchScoreForRanges(firstOccurrenceMatches)
          @matchedRanges = reverseSearchMatches
        else
          @matchedRanges = firstOccurrenceMatches
        end
        return true
      end
      @matchedRanges = firstOccurrenceMatches
      return true
    end
    return nil
  end

  def searchText(theText, forFirstOccurrenceOfString:searchString)
    matchingRanges = []

    upcaseText = theText.upcase
    upcaseSearchString = searchString.upcase

    upcaseSearchString.each_char do |c|
      offset = 0
      if matchingRanges.length > 0
        offset =
          matchingRanges.lastObject.location + matchingRanges.lastObject.length
      end
      if (foundIndex = upcaseText.index(c, offset))
        if contiguousMatch?(foundIndex, matchingRanges)
          lastRange       = matchingRanges.lastObject
          lastObjectIndex = matchingRanges.length - 1
          matchingRanges[lastObjectIndex] = NSMakeRange(lastRange.location,
                                                        lastRange.length + 1)
        else
          matchingRanges << NSMakeRange(foundIndex, 1)
        end
      else
        # No match or partial match
        return nil
      end
    end

    if matchingRanges.length > 0
      return matchingRanges
    end
    nil
  end

  def searchInReverseForString(searchString)
    reverseMatches = searchText(filePath.reverse,
                                forFirstOccurrenceOfString:searchString.reverse)
    if reverseMatches.length > 0
      forwardMatches = reverseMatches.reverse.map { |range|
        location = filePath.length - range.location - range.length
        NSMakeRange(location, range.length)
      }
      return forwardMatches
    end
    nil
  end

  def resetMatches!
    @matchesOnFilenameScore = 0
    @matchedRanges = nil
    @matchScore    = nil
    @longestMatch  = nil
  end

  def matchScore
    return MAX_SCORE if @matchedRanges.nil? || @matchedRanges.length == 0
    # TODO: Files with locations close together should rank higher
    #       than ones with locations farther apart.
    #       FuzzyRecord_test.rb
    #       FuzzyRecord.rb
    #       Search => fuzr.rb
    @matchScore ||= calculateMatchScoreForRanges(@matchedRanges)
  end

  def calculateMatchScoreForRanges(ranges)
    ranges.inject(0) {|memo, element|
      memo + element.location }
  end

  def longestMatch
    return 0 if @matchedRanges.nil? || @matchedRanges.length == 0
    @longestMatch ||= calculateLongestMatch(@matchedRanges)
  end

  def calculateLongestMatch(ranges)
    longest = 0
    ranges.each do |range|
      if range.length > longest
        longest = range.length
      end
    end
    return longest
  end

  def modifiedAt
    @modifiedAt ||= begin
                      NSFileManager.defaultManager.
                        attributesOfItemAtPath(absFilePath,
                                               error:nil)[NSFileModificationDate]
                    end
  end

  def scmStatus
    return @scmStatus if @scmStatus

    if statusCounts = @@scmStatusDictionary.objectForKey(filePath)
      linesAdded, linesDeleted = statusCounts
      @scmStatus = ("+" * linesAdded) + ("-" * linesDeleted)
    end
    return @scmStatus
  end

  def absFilePath
    File.join(projectRoot, filePath)
  end

  def contiguousMatch?(foundIndex, matchingRanges)
    return false if (matchingRanges.length == 0)
    lastObject = matchingRanges.lastObject
    return (lastObject.location + lastObject.length == foundIndex)
  end
  
  ##
  # Make a new array of ranges, moved forward by a number of
  # characters.
  #
  # Used for switching filename-only match to a full path match.
  
  def offsetRanges(theRanges, by:theOffset)
    theRanges.map do |range|
      NSMakeRange(range.location + theOffset + 1, range.length)
    end
  end  
  
end

