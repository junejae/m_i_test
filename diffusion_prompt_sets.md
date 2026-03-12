# Diffusion Prompt Sets

Small prompt set for validating `slot7` Stable Diffusion v1.5 quality and response behavior.

Recommended baseline:

```text
width=512
height=512
steps=20
guidance=7.5
negative=blurry, low-quality, distorted, extra fingers, bad anatomy
```

## 1. Character Illustration

Prompt:

```text
a small robot reading a book in a cozy library, clean illustration, soft lighting, highly detailed
```

What to check:
- subject appears once
- book is readable as an object
- lighting and composition are coherent

## 2. Product Shot

Prompt:

```text
studio product photo of a matte white wireless earbud case on a minimal pedestal, soft shadows, commercial photography
```

What to check:
- object silhouette is clean
- highlights and shadows look physically plausible
- background is uncluttered

## 3. Landscape

Prompt:

```text
wide scenic view of a mountain lake at sunrise, reflections on calm water, cinematic atmosphere, detailed environment
```

What to check:
- horizon and perspective are stable
- reflections roughly match the scene
- no obvious duplicated objects

## 4. Interior

Prompt:

```text
modern Korean cafe interior with warm wood furniture, indoor plants, sunlight through large windows, editorial photography
```

What to check:
- furniture geometry is reasonable
- room depth feels natural
- window light direction is consistent

## 5. Poster Style

Prompt:

```text
retro travel poster of Seoul skyline, bold typography space, flat graphic design, vibrant colors
```

What to check:
- style consistency
- composition leaves poster-like negative space
- buildings do not melt together excessively

## 6. Failure-Reproduction Stress Prompt

Prompt:

```text
crowded fantasy marketplace with many characters, intricate clothing, signs, animals, stalls, dramatic sunset lighting, ultra detailed
```

What to check:
- latency increase
- malformed hands/faces
- whether the server stays stable after heavier prompts

## Suggested Test Order

1. Character Illustration
2. Product Shot
3. Landscape
4. Interior
5. Poster Style
6. Failure-Reproduction Stress Prompt
