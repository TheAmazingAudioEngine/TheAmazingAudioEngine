//
//  RecordingsTableViewCell.h
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/5/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "MoreButtonIcon.h"

@interface RecordingsTableViewCell : UITableViewCell

@property (weak, nonatomic) IBOutlet UILabel *titleLabel;
@property (weak, nonatomic) IBOutlet UILabel *detailsLabel;
@property (weak, nonatomic) IBOutlet MoreButtonIcon *moreButtonIcon;
@property (weak, nonatomic) IBOutlet UIView *bottomHairlineView;

@end
