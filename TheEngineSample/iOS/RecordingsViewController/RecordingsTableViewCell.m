//
//  RecordingsTableViewCell.m
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/5/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import "RecordingsTableViewCell.h"

@interface RecordingsTableViewCell ()

@property (nonatomic, strong) NSArray *documentsFolders;
@property (nonatomic, strong) NSArray *directoryContent;
@property (nonatomic, strong) NSString *recordingPath;

@end

@implementation RecordingsTableViewCell

- (void)awakeFromNib {
    _bottomHairlineView.backgroundColor = [UIColor colorWithRed:200.0/255.0 green:200.0/255.0 blue:200.0/255.0 alpha:1.0];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    
    _documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    _recordingPath = _documentsFolders[0];
    _directoryContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_recordingPath error:NULL];
    
    if (_directoryContent.count > 0) {
        if(selected) {
            _titleLabel.textColor = [UIColor whiteColor];
            _detailsLabel.textColor = [UIColor whiteColor];
            _moreButtonIcon.red = 255.0;
            _moreButtonIcon.green = 255.0;
            _moreButtonIcon.blue = 255.0;
            _moreButtonIcon.alpha = 1.0;
            _bottomHairlineView.backgroundColor = [UIColor whiteColor];
        } else {
            _titleLabel.textColor = [UIColor darkGrayColor];
            _detailsLabel.textColor = [UIColor darkGrayColor];
            _moreButtonIcon.red = 45.0;
            _moreButtonIcon.green = 45.0;
            _moreButtonIcon.blue = 45.0;
            _moreButtonIcon.alpha = 1.0;
            _bottomHairlineView.backgroundColor = [UIColor colorWithRed:190.0/255.0 green:190.0/255.0 blue:190.0/255.0 alpha:1.0];
        }
    }
}

@end
