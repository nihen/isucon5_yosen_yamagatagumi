alter table users ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table salts ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table relations ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table profiles ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table footprints ENGINE=InnoDB ROW_FORMAT=COMPRESSED;
alter table entries ENGINE=InnoDB ROW_FORMAT=COMPRESSED;

ALTER TABLE comments 
ADD to_user_id int(11) NOT NULL,
ADD KEY `user_id` (`user_id`),
ADD KEY `to_user_id` (`to_user_id`),
ROW_FORMAT=COMPRESSED
;


UPDATE comments c
 INNER JOIN entries e ON (c.entry_id = e.id)
 SET c.to_user_id = e.user_id;

