module Main (main) where

import SourceExplorer.Parser
import Test.Hspec

main :: IO ()
main =
  hspec $ do
    describe "detectLanguage" $ do
      it "detects initial supported languages" $ do
        detectLanguage "Program.cs" `shouldBe` Just "csharp"
        detectLanguage "index.js" `shouldBe` Just "javascript"
        detectLanguage "component.tsx" `shouldBe` Just "typescript"

    describe "parseSymbols" $ do
      it "extracts TypeScript functions and classes" $ do
        let symbols = parseSymbols "typescript" "export class Project {}\nexport function run() {}\nconst load = () => true"
        map symbolName symbols `shouldContain` ["Project", "run", "load"]

      it "extracts C# classes and methods" $ do
        let symbols = parseSymbols "csharp" "public class Project {\npublic void Run() {\n}\n}"
        map symbolName symbols `shouldContain` ["Project", "Run"]

