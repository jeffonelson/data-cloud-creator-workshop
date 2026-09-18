CREATE OR REPLACE TABLE `@WORKSHOP_DATASET@.customer_feedback` AS
SELECT
  feedback_id,
  business_id,
  business_name,
  business_type,
  zip_code,
  rating,
  source,
  review_date,
  TRIM(AI.GENERATE(
    CONCAT(
      'Write one fictional customer review for a synthetic workshop dataset, two sentences and under 45 words, of ',
      business_name,
      ', a coffee shop in San Francisco, California. Tone: ', tone,
      '. Focus on ', topic,
      '. Mention one concrete detail. Do not use the words amazing or incredible. ',
      'Return only the review text with no quotation marks.'
    )
  ).result) AS review_text
FROM `@WORKSHOP_DATASET@.feedback_seed`;
