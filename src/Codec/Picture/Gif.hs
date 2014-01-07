-- | Module implementing GIF decoding.
module Codec.Picture.Gif ( decodeGif
                         , decodeGifImages
                         ) where

import Control.Applicative( pure, (<$>), (<*>) )
import Control.Monad( replicateM )
import Control.Monad.ST( runST )
import Control.Monad.Trans.Class( lift )

import Data.Bits( (.&.), (.|.)
                , unsafeShiftR
                , unsafeShiftL
                , testBit, setBit )
import Data.Word( Word8, Word16 )

import qualified Data.ByteString as B
import qualified Data.Vector.Storable as V
import qualified Data.Vector.Storable.Mutable as M

import Data.Binary( Binary(..) )
import Data.Binary.Get( Get
                      , getWord8
                      , getWord16le
                      , getByteString
                      )

import Data.Binary.Put( Put
                      , putWord8
                      , putWord16le
                      , putByteString
                      )

import Codec.Picture.InternalHelper
import Codec.Picture.Types
import Codec.Picture.Gif.LZW
import Codec.Picture.Gif.LZWEncoding
import Codec.Picture.BitWriter

{-
   <GIF Data Stream> ::=     Header <Logical Screen> <Data>* Trailer

   <Logical Screen> ::=      Logical Screen Descriptor [Global Color Table]

   <Data> ::=                <Graphic Block>  |
                             <Special-Purpose Block>

   <Graphic Block> ::=       [Graphic Control Extension] <Graphic-Rendering Block>

   <Graphic-Rendering Block> ::=  <Table-Based Image>  |
                                  Plain Text Extension

   <Table-Based Image> ::=   Image Descriptor [Local Color Table] Image Data

   <Special-Purpose Block> ::=    Application Extension  |
                                  Comment Extension
 -}

--------------------------------------------------
----            GifVersion
--------------------------------------------------
data GifVersion = GIF87a | GIF89a

gif87aSignature, gif89aSignature :: B.ByteString
gif87aSignature = B.pack $ map (fromIntegral . fromEnum) "GIF87a"
gif89aSignature = B.pack $ map (fromIntegral . fromEnum) "GIF89a"

instance Binary GifVersion where
    put GIF87a = put gif87aSignature
    put GIF89a = put gif89aSignature

    get = do
        sig <- getByteString (B.length gif87aSignature)
        case (sig == gif87aSignature, sig == gif89aSignature) of
            (True, _)  -> pure GIF87a
            (_ , True) -> pure GIF89a
            _          -> fail $ "Invalid Gif signature : " ++ (toEnum . fromEnum <$> B.unpack sig)


--------------------------------------------------
----         LogicalScreenDescriptor
--------------------------------------------------
-- | Section 18 of spec-gif89a
data LogicalScreenDescriptor = LogicalScreenDescriptor
  { -- | Stored on 16 bits
    screenWidth           :: !Word16
    -- | Stored on 16 bits
  , screenHeight          :: !Word16
    -- | Stored on 8 bits
  , backgroundIndex       :: !Word8

  -- | Stored on 1 bit
  , hasGlobalMap          :: !Bool
  -- | Stored on 3 bits
  , colorResolution       :: !Word8
  -- | Stored on 1 bit
  , isColorTableSorted    :: !Bool
  -- | Stored on 3 bits
  , colorTableSize        :: !Word8
  }

instance Binary LogicalScreenDescriptor where
    put v = do
      putWord16le $ screenWidth v
      putWord16le $ screenHeight v
      let globalMapField
            | hasGlobalMap v = 0x80
            | otherwise = 0

          colorTableSortedField
            | isColorTableSorted v = 0x08
            | otherwise = 0

          tableSizeField = (colorTableSize v - 1) .&. 7

          colorResolutionField = 
            ((colorResolution v - 1) .&. 7) `unsafeShiftL` 5

          packedField = globalMapField
                     .|. colorTableSortedField
                     .|. tableSizeField
                     .|. colorResolutionField

      putWord8 packedField
      putWord8 0 -- aspect ratio
      putWord8 $ backgroundIndex v

    get = do
        w <- getWord16le
        h <- getWord16le
        packedField  <- getWord8
        backgroundColorIndex  <- getWord8
        _aspectRatio  <- getWord8
        return LogicalScreenDescriptor
            { screenWidth           = w
            , screenHeight          = h
            , hasGlobalMap          = packedField `testBit` 7
            , colorResolution       = (packedField `unsafeShiftR` 5) .&. 0x7 + 1
            , isColorTableSorted    = packedField `testBit` 3
            , colorTableSize        = (packedField .&. 0x7) + 1
            , backgroundIndex       = backgroundColorIndex
            }


--------------------------------------------------
----            ImageDescriptor
--------------------------------------------------
-- | Section 20 of spec-gif89a
data ImageDescriptor = ImageDescriptor
  { gDescPixelsFromLeft         :: !Word16
  , gDescPixelsFromTop          :: !Word16
  , gDescImageWidth             :: !Word16
  , gDescImageHeight            :: !Word16
  , gDescHasLocalMap            :: !Bool
  , gDescIsInterlaced           :: !Bool
  , gDescIsImgDescriptorSorted  :: !Bool
  , gDescLocalColorTableSize    :: !Word8
  }

imageSeparator, extensionIntroducer, gifTrailer :: Word8
imageSeparator      = 0x2C
extensionIntroducer = 0x21
gifTrailer          = 0x3B

graphicControlLabel :: Word8
graphicControlLabel = 0xF9

--commentLabel, graphicControlLabel, applicationLabel
--
{-commentLabel        = 0xFE-}
{-plainTextLabel      = 0x01-}
{-applicationLabel    = 0xFF-}

parseDataBlocks :: Get B.ByteString
parseDataBlocks = B.concat <$> (getWord8 >>= aux)
 where aux    0 = pure []
       aux size = (:) <$> getByteString (fromIntegral size) <*> (getWord8 >>= aux)

putDataBlocks :: B.ByteString -> Put
putDataBlocks wholeString = putSlices wholeString >> putWord8 0
  where putSlices str | B.length str == 0 = pure ()
                      | B.length str > 0xFF =
            let (before, after) = B.splitAt 0xFF str in
            putWord8 0xFF >> putByteString before >> putSlices after
        putSlices str =
            putWord8 (fromIntegral $ B.length str) >> putByteString str
     

data GraphicControlExtension = GraphicControlExtension
    { gceDisposalMethod        :: !Word8 -- ^ Stored on 3 bits
    , gceUserInputFlag         :: !Bool
    , gceTransparentFlag       :: !Bool
    , gceDelay                 :: !Word16
    , gceTransparentColorIndex :: !Word8
    }

instance Binary GraphicControlExtension where
    put v = do
        putWord8 extensionIntroducer
        putWord8 0x4  -- size
        let disposalField =
                (gceDisposalMethod v .&. 0x7) `unsafeShiftL` 2

            userInputField 
                | gceUserInputFlag v = 0 `setBit` 1
                | otherwise = 0

            transparentField
                | gceTransparentFlag v = 0 `setBit` 0 
                | otherwise = 0

            packedFields =  disposalField
                        .|. userInputField
                        .|. transparentField

        putWord8 packedFields
        putWord16le $ gceDelay v
        putWord8 $ gceTransparentColorIndex v
        putWord8 0 -- blockTerminator

    get = do
        -- due to missing lookahead
        {-_extensionLabel  <- getWord8-}
        _size            <- getWord8
        packedFields     <- getWord8
        delay            <- getWord16le
        idx              <- getWord8
        _blockTerminator <- getWord8
        return GraphicControlExtension
            { gceDisposalMethod        = (packedFields `unsafeShiftR` 2) .&. 0x07
            , gceUserInputFlag         = packedFields `testBit` 1
            , gceTransparentFlag       = packedFields `testBit` 0
            , gceDelay                 = delay
            , gceTransparentColorIndex = idx
            }

data GifImage = GifImage
    { imgDescriptor   :: !ImageDescriptor
    , imgLocalPalette :: !(Maybe Palette)
    , imgLzwRootSize  :: !Word8
    , imgData         :: B.ByteString
    }

instance Binary GifImage where
    put img = do
        put $ imgDescriptor img
        case imgLocalPalette img of
          Nothing -> return ()
          Just p -> putPalette p
        putWord8 $ imgLzwRootSize img
        putDataBlocks $ imgData img

    get = do
        desc <- get
        let hasLocalColorTable = gDescHasLocalMap desc
        palette <- if hasLocalColorTable
           then Just <$> getPalette (gDescLocalColorTableSize desc)
           else pure Nothing

        GifImage desc palette <$> getWord8 <*> parseDataBlocks

data Block = BlockImage GifImage
           | BlockGraphicControl GraphicControlExtension

parseGifBlocks :: Get [Block]
parseGifBlocks = getWord8 >>= blockParse
  where blockParse v
          | v == gifTrailer = pure []
          | v == imageSeparator = (:) <$> (BlockImage <$> get) <*> parseGifBlocks
          | v == extensionIntroducer = do
                extensionCode <- getWord8
                if extensionCode /= graphicControlLabel
                   then parseDataBlocks >> parseGifBlocks
                   else (:) <$> (BlockGraphicControl <$> get) <*> parseGifBlocks

        blockParse v = do
            fail ("Unrecognized gif block " ++ show v)

instance Binary ImageDescriptor where
    put v = do
        putWord8 imageSeparator
        putWord16le $ gDescPixelsFromLeft v
        putWord16le $ gDescPixelsFromTop v
        putWord16le $ gDescImageWidth v
        putWord16le $ gDescImageHeight v
        let localMapField 
                | gDescHasLocalMap v = 0 `setBit` 7
                | otherwise = 0

            isInterlacedField
                | gDescIsInterlaced v = 0 `setBit` 6
                | otherwise = 0

            isImageDescriptorSorted
                | gDescIsImgDescriptorSorted v = 0 `setBit` 5
                | otherwise = 0

            localSize = gDescLocalColorTableSize v
            tableSizeField
                | localSize > 0 = (localSize - 1) .&. 0x7
                | otherwise = 0

            packedFields = localMapField
                        .|. isInterlacedField
                        .|. isImageDescriptorSorted
                        .|. tableSizeField
        putWord8 packedFields

    get = do
        -- due to missing lookahead
        {-_imageSeparator <- getWord8-}
        imgLeftPos <- getWord16le
        imgTopPos  <- getWord16le
        imgWidth   <- getWord16le
        imgHeight  <- getWord16le
        packedFields <- getWord8
        let tableSize = packedFields .&. 0x7
        return ImageDescriptor
            { gDescPixelsFromLeft = imgLeftPos
            , gDescPixelsFromTop  = imgTopPos
            , gDescImageWidth     = imgWidth
            , gDescImageHeight    = imgHeight
            , gDescHasLocalMap    = packedFields `testBit` 7
            , gDescIsInterlaced     = packedFields `testBit` 6
            , gDescIsImgDescriptorSorted = packedFields `testBit` 5
            , gDescLocalColorTableSize = if tableSize > 0 then tableSize + 1 else 0
            }


--------------------------------------------------
----            Palette
--------------------------------------------------
type Palette = Image PixelRGB8

getPalette :: Word8 -> Get Palette
getPalette bitDepth = replicateM (size * 3) get >>= return . Image size 1 . V.fromList
  where size = 2 ^ (fromIntegral bitDepth :: Int)

putPalette :: Palette -> Put
putPalette = mapM_ putWord8 . V.toList . imageData

--------------------------------------------------
----            GifImage
--------------------------------------------------
data GifHeader = GifHeader
  { gifVersion          :: GifVersion
  , gifScreenDescriptor :: LogicalScreenDescriptor
  , gifGlobalMap        :: !Palette
  }

instance Binary GifHeader where
    put v = do
      put $ gifVersion v
      put $ gifScreenDescriptor v
      putPalette $ gifGlobalMap v

    get = do
        version    <- get
        screenDesc <- get
        palette    <- getPalette $ colorTableSize screenDesc
        return GifHeader
            { gifVersion = version
            , gifScreenDescriptor = screenDesc
            , gifGlobalMap = palette
            }

data GifFile = GifFile
    { gifHeader  :: !GifHeader
    , gifImages  :: [(Maybe GraphicControlExtension, GifImage)]
    }

associateDescr :: [Block] -> [(Maybe GraphicControlExtension, GifImage)]
associateDescr [] = []
associateDescr [BlockGraphicControl _] = []
associateDescr (BlockGraphicControl _ : rest@(BlockGraphicControl _ : _)) = associateDescr rest
associateDescr (BlockImage img:xs) = (Nothing, img) : associateDescr xs
associateDescr (BlockGraphicControl ctrl : BlockImage img : xs) =
    (Just ctrl, img) : associateDescr xs

instance Binary GifFile where
    put v = do
        put $ gifHeader v
        let putter (Nothing, i) = put i
            putter (Just a, i) = put a >> put i
        mapM_ putter $ gifImages v
        put gifTrailer
        
    get = do
        hdr <- get
        blocks <- parseGifBlocks
        return GifFile { gifHeader = hdr
                       , gifImages = associateDescr blocks }

substituteColors :: Palette -> Image Pixel8 -> Image PixelRGB8
substituteColors palette = pixelMap swaper
  where swaper n = pixelAt palette (fromIntegral n) 0

decodeImage :: GifImage -> Image Pixel8
decodeImage img = runST $ runBoolReader $ do
    outputVector <- lift . M.new $ width * height
    decodeLzw (imgData img) 12 lzwRoot outputVector
    frozenData <- lift $ V.unsafeFreeze outputVector
    return . deinterlaceGif $ Image
      { imageWidth = width
      , imageHeight = height
      , imageData = frozenData
      }
  where lzwRoot = fromIntegral $ imgLzwRootSize img
        width = fromIntegral $ gDescImageWidth descriptor
        height = fromIntegral $ gDescImageHeight descriptor
        isInterlaced = gDescIsInterlaced descriptor
        descriptor = imgDescriptor img

        deinterlaceGif | not isInterlaced = id
                       | otherwise = deinterlaceGifImage

deinterlaceGifImage :: Image Pixel8 -> Image Pixel8
deinterlaceGifImage img@(Image { imageWidth = w, imageHeight = h }) = generateImage generator w h
   where lineIndices = gifInterlacingIndices h
         generator x y = pixelAt img x y'
            where y' = lineIndices V.! y

gifInterlacingIndices :: Int -> V.Vector Int
gifInterlacingIndices height = V.accum (\_ v -> v) (V.replicate height 0) indices
    where indices = flip zip [0..] $
                concat [ [0,     8 .. height - 1]
                       , [4, 4 + 8 .. height - 1]
                       , [2, 2 + 4 .. height - 1]
                       , [1, 1 + 2 .. height - 1]
                       ]

paletteOf :: Palette -> GifImage -> Palette
paletteOf global GifImage { imgLocalPalette = Nothing } = global
paletteOf      _ GifImage { imgLocalPalette = Just p  } = p

decodeAllGifImages :: GifFile -> [Image PixelRGB8]
decodeAllGifImages GifFile { gifImages = [] } = []
decodeAllGifImages GifFile { gifHeader = GifHeader { gifGlobalMap = palette
                                                   , gifScreenDescriptor = wholeDescriptor
                                                   }
                           , gifImages = (_, firstImage) : rest } = map paletteApplyer $
 scanl generator (paletteOf palette firstImage, decodeImage firstImage) rest
    where globalWidth = fromIntegral $ screenWidth wholeDescriptor
          globalHeight = fromIntegral $ screenHeight wholeDescriptor

          {-background = backgroundIndex wholeDescriptor-}

          paletteApplyer (pal, img) = substituteColors pal img

          generator (_, img1) (controlExt, img2@(GifImage { imgDescriptor = descriptor })) =
                        (paletteOf palette img2, generateImage pixeler globalWidth globalHeight)
               where localWidth = fromIntegral $ gDescImageWidth descriptor
                     localHeight = fromIntegral $ gDescImageHeight descriptor

                     left = fromIntegral $ gDescPixelsFromLeft descriptor
                     top = fromIntegral $ gDescPixelsFromTop descriptor

                     isPixelInLocalImage x y =
                         x >= left && x < left + localWidth && y >= top && y < top + localHeight

                     decoded = decodeImage img2

                     transparent :: Int
                     transparent = case controlExt of
                        Nothing  -> 300
                        Just ext -> if gceTransparentFlag ext
                            then fromIntegral $ gceTransparentColorIndex ext
                            else 300

                     pixeler x y
                        | isPixelInLocalImage x y && fromIntegral val /= transparent = val
                            where val = pixelAt decoded (x - left) (y - top)
                     pixeler x y = pixelAt img1 x y

decodeFirstGifImage :: GifFile -> Either String (Image PixelRGB8)
decodeFirstGifImage
        GifFile { gifHeader = GifHeader { gifGlobalMap = palette}
                , gifImages = ((_, gif):_) } = Right . substituteColors palette $ decodeImage gif
decodeFirstGifImage _ = Left "No image in gif file"

-- | Transform a raw gif image to an image, witout
-- modifying the pixels.
-- This function can output the following pixel types :
--
--  * PixelRGB8
--
decodeGif :: B.ByteString -> Either String DynamicImage
decodeGif img = ImageRGB8 <$> (decode img >>= decodeFirstGifImage)

-- | Transform a raw gif to a list of images, representing
-- all the images of an animation.
decodeGifImages :: B.ByteString -> Either String [Image PixelRGB8]
decodeGifImages img = decodeAllGifImages <$> decode img

