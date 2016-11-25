//
//  RecordingsTVC.m
//  TheEngineSample
//
//  Created by Jeschke, Mark on 3/1/16.
//  Copyright © 2016 A Tasty Pixel. All rights reserved.
//

#import "RecordingsTVC.h"
#import <QuartzCore/QuartzCore.h>
#import "ViewController.h"
#import "TheAmazingAudioEngine.h"
#import "MoreButtonIcon.h"
#import <MobileCoreServices/UTCoreTypes.h>
#import "RecordingsTableViewCell.h"
#import "FilesizeFormatter.h"

@interface RecordingsTVC ()

@property (nonatomic, strong) NSUserDefaults *defaults;
@property (nonatomic, strong) NSArray *documentsFolders;
@property (nonatomic, strong) NSArray *directoryContent;
@property (nonatomic, strong) NSString *recordingPath;
@property (nonatomic, strong) NSArray *sortedFiles;
@property (nonatomic, strong) NSDictionary *fileAttribs;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) NSString *currentAudioClip;
@property (weak, nonatomic) NSString *renamedFile;
@property (weak, nonatomic) NSString *deleteMessageText;
@property (nonatomic) BOOL renameFile;
@property (nonatomic) BOOL currentlyEditingTableCell;
@property (nonatomic) int selection;
@property (strong, nonatomic) MoreButtonIcon *MoreButtonIcon;
@property (nonatomic, strong) RecordingsTableViewCell *recordingsTableViewCell;
@property (nonatomic, strong) FilesizeFormatter *filesizeFormatter;
@property (nonatomic, strong) NSNumber *fileSize;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@property (nonatomic, strong) NSDateFormatter *timeFormatter;
@property (nonatomic, strong) NSMutableArray *timecodeDurationArray;
@property (nonatomic, strong) NSDate *creationDate;

@end

@implementation RecordingsTVC

#pragma mark -
#pragma mark === View Lifecycle ===
#pragma mark

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor groupTableViewBackgroundColor];
    
    // Create Key-Value Observer (KVO) listener for when to deselect the table row.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deselectTableRow) name:@"deselect_table_row" object:nil];
    
    _defaults = [NSUserDefaults standardUserDefaults];
    _filesizeFormatter = [[FilesizeFormatter alloc] init];
    
    _currentlyEditingTableCell = false;
    _renameFile = false;
    _selection = -1;
    _documentsFolders = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    _recordingPath = _documentsFolders[0];
    
    [self listFiles];
    
    self.tableView.estimatedRowHeight = 80;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    
    UIBarButtonItem *flexiableItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];
    UIBarButtonItem *item1 = [[UIBarButtonItem alloc] initWithTitle:_deleteMessageText style:NO target:self action:@selector(deleteAllFilesWarning:)];
    UIBarButtonItem *item2 = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(deleteAllFilesWarning:)];
    NSArray *items = [NSArray arrayWithObjects:flexiableItem, item1, item2, nil];
    self.toolbarItems = items;
    
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_directoryContent.count > 0) {
        self.navigationItem.rightBarButtonItem = self.editButtonItem;
        NSArray *timecodeArray = [_defaults objectForKey:@"timecodeDurationArray"];
        _timecodeDurationArray = [NSMutableArray arrayWithArray:timecodeArray];
    }
    self.title = @"Recordings";
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

#pragma mark -
#pragma mark === List All Audio Files Found ===
#pragma mark

-(void) listFiles {
    
    _directoryContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_recordingPath error:NULL];
    
    if (_directoryContent.count > 0) {
        _deleteMessageText = @"Delete all recordings";
        [self.navigationController setToolbarHidden:NO animated:YES];
        
        // sort by creation date
        NSMutableArray* filesAndProperties = [NSMutableArray arrayWithCapacity:[_directoryContent count]];
        
        int timecodeCount = 0;
        
        for(NSString* file in _directoryContent) {
            NSError *error = nil;
            if (![file isEqualToString:@".DS_Store"]) {
                NSString* filePath = [_recordingPath stringByAppendingPathComponent:file];
                NSDictionary* properties = [[NSFileManager defaultManager]
                                            attributesOfItemAtPath:filePath
                                            error:&error];
                NSDate* modDate = [properties objectForKey:NSFileModificationDate];
                
                //NSDate* modDate = [properties objectForKey:NSFileSize];
                
                [filesAndProperties addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                               file, @"path",
                                               modDate, @"lastModDate",
                                               nil]];
            }
            timecodeCount++;
        }
        
        // Sort using a block - order inverted as we want latest date first
        _sortedFiles = [filesAndProperties sortedArrayUsingComparator:
                        ^(id path1, id path2)
                        {
                            // compare
                            NSComparisonResult comp = [[path1 objectForKey:@"lastModDate"] compare:
                                                       [path2 objectForKey:@"lastModDate"]];
                            // invert ordering
                            if (comp == NSOrderedDescending) {
                                comp = NSOrderedAscending;
                            }
                            else if(comp == NSOrderedAscending){
                                comp = NSOrderedDescending;
                            }
                            return comp;
                        }];
        
    } else {
        [self.navigationController setToolbarHidden:YES animated:YES];
    }
}

- (void)deselectTableRow {
    [self.tableView deselectRowAtIndexPath:[NSIndexPath indexPathForRow:_selection inSection:0] animated:YES];
}

#pragma mark -
#pragma mark === Delete Recordings ===
#pragma mark

- (void) deleteAllFilesWarning:(id)sender {
    
    UIAlertController *alertController = [UIAlertController
                                          alertControllerWithTitle:_deleteMessageText
                                          message:@"Are you sure?"
                                          preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"Yes", @"OK action")
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action)
                               {
                                   [self deleteFiles];
                                   
                               }];
    
    UIAlertAction *cancelAction = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"No", @"Cancel action")
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction *action)
                                   {
                                       //NSLog(@"Cancel action");
                                   }];
    
    [alertController addAction:okAction];
    [alertController addAction:cancelAction];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void) deleteFiles {
    
    NSString *path;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    path = [paths objectAtIndex:0];
    
    _directoryContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_recordingPath error:NULL];
    
    int Count = 0;
    
    if ([_directoryContent count] > 0)
    {
        NSError *error = nil;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        
        for (NSString *file in _directoryContent) {
            
            NSString *filePath = [path stringByAppendingPathComponent:file];
            
            BOOL fileDeleted = [fileManager removeItemAtPath:filePath error:&error];

            Count++;
            if (fileDeleted != YES || error != nil)
            {
                // Deal with the error...
            }
        }
        
        [self listFiles];
        [_timecodeDurationArray removeAllObjects];
        [_defaults setObject:_timecodeDurationArray forKey:@"timecodeDurationArray"];
        
        __weak RecordingsTVC *weakSelf = self;
        [weakSelf reloadTableView];
    }
}

#pragma mark -
#pragma mark === Share Button Action ===
#pragma mark

- (void)shareButtonAction:(id)sender {
    // Get the button index of the desired TableViewCell.
    CGPoint buttonPosition = [sender convertPoint:CGPointZero toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:buttonPosition];
    
    _selection = (int)indexPath.row;
    
    if (indexPath != nil && !_currentlyEditingTableCell)
    {
        NSString *fileName = [_sortedFiles valueForKey:@"path"][indexPath.row];
        [_defaults setObject:fileName forKey:@"currentAudioClip"];
        [_defaults setInteger:(long)indexPath.row forKey:@"currentSelectionIndex"];
        // Remove filename extension.
        NSString* nameWithoutExtension = [fileName stringByDeletingPathExtension];
        
        UIAlertController *alertController = [UIAlertController
                                              alertControllerWithTitle:[NSString stringWithFormat:@"\"%@\"",nameWithoutExtension]
                                              message:nil
                                              preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *cancelAction = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel action")
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action)
                                       {
                                           ////NSLog(@"Cancel action");
                                       }];
        
        UIAlertAction *emailAction = [UIAlertAction
                                      actionWithTitle:NSLocalizedString(@"Export to email", @"Export to email action")
                                      style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction *action)
                                      {
                                          ////NSLog(@"Export to email action");
                                          [self emailAudio:self];
                                      }];
        
        UIAlertAction *renameAction = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"Rename this file", @"Rename this file action")
                                       style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *action)
                                       {
                                           ////NSLog(@"Rename this file action");
                                           _renameFile = true;
                                           [self renameFileAction];
                                       }];
        
        [alertController addAction:cancelAction];
        [alertController addAction:emailAction];
        [alertController addAction:renameAction];
        
        [self presentViewController:alertController animated:YES completion:nil];
    }
}

#pragma mark -
#pragma mark === Email Action ===
#pragma mark

-(IBAction)emailAudio:(id)sender {
    
    _currentAudioClip = [_defaults objectForKey:@"currentAudioClip"];
    
    NSString* nameWithoutExtension = [_currentAudioClip stringByDeletingPathExtension];
    
    NSString *path = [_recordingPath stringByAppendingPathComponent:_currentAudioClip];
    
    NSData *audioData = [NSData dataWithContentsOfFile:path];
    
    _fileAttribs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];

    _fileSize = _fileAttribs[NSFileSize];
    _creationDate = nil;
    _creationDate = _fileAttribs[NSFileCreationDate];
    _dateFormatter = [[NSDateFormatter alloc] init];
    [_dateFormatter setDateFormat:@"M/d/yy"];
    _timeFormatter = [[NSDateFormatter alloc] init];
    [_timeFormatter setDateFormat:@"h:mm a"];
    NSString *convertedSize = [_filesizeFormatter transformedValue:_fileSize];
    NSString *formattedDate = [_dateFormatter stringFromDate:_creationDate];
    NSString *formattedTime = [_timeFormatter stringFromDate:_creationDate];
    NSArray* reversedArray = [[_timecodeDurationArray reverseObjectEnumerator] allObjects];
    NSString *timecodeDuration = reversedArray[_selection];
    NSString *fileInfo = [NSString stringWithFormat:@"<br />Date: %@<br />Time: %@<br />Size: %@<br />Duration: %@",formattedDate, formattedTime, convertedSize, timecodeDuration];
    
    MFMailComposeViewController *mailer = [[MFMailComposeViewController alloc] init];
    
    [mailer setMailComposeDelegate:self];
    
    if ([MFMailComposeViewController canSendMail]) {
        
        NSString* audioTitle = [NSString stringWithFormat:@"%@", nameWithoutExtension];
        
        NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey];
        
        [mailer setSubject:[NSString stringWithFormat: @"%@", audioTitle]];
        
        [mailer setMessageBody:[NSString stringWithFormat:@"Check out \"%@,\" exported from %@<br />%@", audioTitle, appName, fileInfo] isHTML:YES];
        
        //[mailer addAttachmentData:audioData mimeType:@"audio/aiff" fileName:[NSString stringWithFormat:@"%@.aif",audioTitle]];
        
        //[mailer addAttachmentData:audioData mimeType:@"audio/wav" fileName:[NSString stringWithFormat:@"%@.wav",audioTitle]];
        
        [mailer addAttachmentData:audioData mimeType:@"audio/m4a" fileName:[NSString stringWithFormat:@"%@", _currentAudioClip]];
        
        [mailer setModalTransitionStyle:UIModalTransitionStyleCoverVertical];
        
        [self presentViewController:mailer animated:YES completion:nil];
        
    }
}

-(void)mailComposeController:(MFMailComposeViewController *)controller didFinishWithResult:(MFMailComposeResult)result error:(NSError *)error {
    
    if (error) {
        
        UIAlertController *alertController = [UIAlertController
                                              alertControllerWithTitle:@"Error"
                                              message:[NSString stringWithFormat:@"error %@", [error description]]
                                              preferredStyle:UIAlertControllerStyleAlert];
        
        UIAlertAction *okAction = [UIAlertAction
                                      actionWithTitle:NSLocalizedString(@"Dismiss", @"Okay action")
                                      style:UIAlertActionStyleDefault
                                      handler:^(UIAlertAction *action)
                                      {
                                          //NSLog(@"Dismiss");
                                      }];
        
        UIAlertAction *cancelAction = [UIAlertAction
                                       actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel action")
                                       style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action)
                                       {
                                           //NSLog(@"Cancel action");
                                       }];
        
        [alertController addAction:okAction];
        [alertController addAction:cancelAction];
        
        [self presentViewController:alertController animated:YES completion:nil];
        
    }
    
    else {
        
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
        
    }
    
}

#pragma mark -
#pragma mark === TableView data source ===
#pragma mark

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    
    if (_directoryContent.count > 0) {
        return _directoryContent.count;
    } else {
        return 1;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    
    static NSString *recordingsTableIdentifier = @"RecordingsTableViewCell";
    
    RecordingsTableViewCell *cell = (RecordingsTableViewCell *)[tableView dequeueReusableCellWithIdentifier:recordingsTableIdentifier];
    
    if (cell == nil)
    {
        NSArray *nib = [[NSBundle mainBundle] loadNibNamed:@"RecordingsTableViewCell" owner:self options:nil];
        cell = [nib objectAtIndex:0];
    }
    
    if (_directoryContent.count > 0) {
        
        UIView *bgView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cell.frame.size.width+10, cell.frame.size.height)];
        bgView.backgroundColor = [UIColor colorWithRed:0.0/255.0 green:122.0/255.0 blue:255.0/255.0 alpha:1.0];
        cell.selectedBackgroundView = bgView;

        _directoryContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_recordingPath error:NULL];
        
        NSString *fileName = [_sortedFiles valueForKey:@"path"][indexPath.row];
        NSArray* reversedArray = [[_timecodeDurationArray reverseObjectEnumerator] allObjects];
        NSString *timecodeDuration = reversedArray[indexPath.row];
        NSString* nameWithoutExtension = [fileName stringByDeletingPathExtension];
        
        NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:nameWithoutExtension];
        NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        [paragraphStyle setLineSpacing:3];
        [attributedString addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, [nameWithoutExtension length])];
        cell.titleLabel.attributedText = attributedString;
        
        NSString *filePath = [_recordingPath stringByAppendingPathComponent:fileName];
        
        _fileAttribs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:NULL];
        _fileSize = _fileAttribs[NSFileSize];
        _creationDate = nil;
        _creationDate = _fileAttribs[NSFileCreationDate];
        _dateFormatter = [[NSDateFormatter alloc] init];
        [_dateFormatter setDateFormat:@"M/d/yy"];
        _timeFormatter = [[NSDateFormatter alloc] init];
        [_timeFormatter setDateFormat:@"h:mm a"];
        NSString *convertedSize = [_filesizeFormatter transformedValue:_fileSize];
        NSString *formattedDate = [_dateFormatter stringFromDate:_creationDate];
        NSString *formattedTime = [_timeFormatter stringFromDate:_creationDate];
        cell.detailsLabel.text = [NSString stringWithFormat:@"%@ • %@ • %@ • %@",formattedDate, formattedTime, convertedSize, timecodeDuration];
        cell.moreButtonIcon.hidden = false;
        self.navigationItem.rightBarButtonItem = self.editButtonItem;
    } else {
        cell.titleLabel.text = @"No recordings found.";
        cell.detailsLabel.text = @"Go back and tap the \"Record\" button.";
        cell.moreButtonIcon.hidden = true;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        self.navigationItem.rightBarButtonItem = nil;
    }
    return cell;
}

#pragma mark -
#pragma mark === TableView delegate ===
#pragma mark

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_directoryContent.count > 0) {
        _selection = (int)indexPath.row;
        NSString *fileName = [_sortedFiles valueForKey:@"path"][indexPath.row];
        _currentAudioClip = fileName;
        [_defaults setObject:fileName forKey:@"currentAudioClip"];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"play_audio_clip" object:self];
    }
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *fileName = [_sortedFiles valueForKey:@"path"][indexPath.row];
    NSString* nameWithoutExtension = [fileName stringByDeletingPathExtension];
    NSString *whichAudioFile = nameWithoutExtension;
    
    
    
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        
        NSString* filePath = [_recordingPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.m4a", whichAudioFile]];
        NSError *error;
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath])		//Does file exist?
        {
            if (![[NSFileManager defaultManager] removeItemAtPath:filePath error:&error])	//Delete it
            {
                //NSLog(@"Delete file error: %@", error);
            } else {
                //NSLog(@"Successfully deleted %@", whichAudioFile);
                [self listFiles];
                if (_directoryContent.count > 0) {
                    
                    NSUInteger Count = indexPath.row;
                    NSUInteger reverseIndex = (_timecodeDurationArray.count-Count)-1;
                    [_timecodeDurationArray removeObjectAtIndex:(long)reverseIndex];
                    [_defaults setObject:_timecodeDurationArray forKey:@"timecodeDurationArray"];
                    
                    [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
                    [NSTimer scheduledTimerWithTimeInterval:0.2
                                                     target:self
                                                   selector:@selector(reloadTableView)
                                                   userInfo:nil
                                                    repeats:NO];
                } else {
                    [self.tableView reloadData];
                    CATransition *transition = [CATransition animation];
                    transition.type = kCATransitionFade;
                    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                    transition.fillMode = kCAFillModeForwards;
                    transition.duration = 0.5f;
                    transition.subtype = kCATransitionFade;
                    [[self.tableView layer] addAnimation:transition forKey:@"UITableViewReloadDataAnimationKey"];
                }
            }
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_directoryContent.count > 0) {
        return YES;
    } else {
        return NO;
    }
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_directoryContent.count > 0) {
        return YES;
    }
    return NO;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row & 1)
    {
        cell.backgroundColor = [UIColor colorWithRed:245.0/255.0 green:245.0/255.0 blue:245.0/255.0 alpha:1.0];
    }
    else
    {
        cell.backgroundColor = [UIColor colorWithRed:255.0/255.0 green:255.0/255.0 blue:255.0/255.0 alpha:1.0];
    }
}

- (void) setEditing:(BOOL)paramEditing
           animated:(BOOL)paramAnimated {
    [super setEditing:paramEditing
             animated:paramAnimated];
    
    if(paramEditing) {
        //NSLog(@"editing is true");
        _currentlyEditingTableCell = true;
    } else {
        //NSLog(@"editing is false");
        _currentlyEditingTableCell = false;
    }
}

- (void) reloadTableView {
    __weak RecordingsTVC *weakSelf = self;
    [weakSelf.tableView reloadData];
    CATransition *transition = [CATransition animation];
    transition.type = kCATransitionFade;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    transition.fillMode = kCAFillModeForwards;
    transition.duration = 0.5f;
    transition.subtype = kCATransitionFade;
    [[weakSelf.tableView layer] addAnimation:transition forKey:@"UITableViewReloadDataAnimationKey"];
}

#pragma mark -
#pragma mark === Rename Audio Recording ===
#pragma mark

- (void)renameFileAction  {
    
    UIAlertController *alertController = [UIAlertController
                                          alertControllerWithTitle:@"Rename this file"
                                          message:nil
                                          preferredStyle:UIAlertControllerStyleAlert];
    
    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField)
     {
         
         _currentAudioClip = [_defaults objectForKey:@"currentAudioClip"];
         
         NSString* nameWithoutExtension = [_currentAudioClip stringByDeletingPathExtension];
         textField.text = nameWithoutExtension;
         textField.autocapitalizationType = UITextAutocapitalizationTypeWords;
         textField.returnKeyType = UIReturnKeyDone;
         textField.keyboardAppearance = UIKeyboardAppearanceDark;
         [textField becomeFirstResponder];
         textField.clearButtonMode = true;
         textField.autocorrectionType = UITextAutocorrectionTypeYes;
         
         [textField addTarget:self
                       action:@selector(alertTextFieldDidChange:)
             forControlEvents:UIControlEventEditingChanged];
         
     }];
    
    UIAlertAction *okAction = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"OK", @"OK action")
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action)
                               {
                                   UITextField *fileNameText = alertController.textFields.firstObject;
                                   _renamedFile = [NSString stringWithFormat:@"%@.m4a", fileNameText.text];
                                   [self checkIfFilenameIsIdentical];
                                   
                               }];
    
    
    UIAlertAction *cancelAction = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel action")
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction *action)
                                   {
                                       //NSLog(@"Cancel action");
                                   }];
    
    
    [alertController addAction:okAction];
    [alertController addAction:cancelAction];
    
    UITextField *fileNameText = alertController.textFields.firstObject;
    okAction.enabled = fileNameText.text.length > 0;
    
    [self presentViewController:alertController animated:YES completion:nil];
    
    _renameFile = false;
    
}

- (void)alertTextFieldDidChange:(UITextField *)sender
{
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController)
    {
        NSString* nameWithoutExtension = [_currentAudioClip stringByDeletingPathExtension];
        
        UITextField *fileNameText = alertController.textFields.firstObject;
        UIAlertAction *okAction = alertController.actions.firstObject;
        fileNameText.placeholder = nameWithoutExtension;
        fileNameText.clearButtonMode = true;
        okAction.enabled = fileNameText.text.length > 0;
    }
}

- (void) fileRenamed {
    _currentAudioClip = [_defaults objectForKey:@"currentAudioClip"];
    [self renameFileFrom:_currentAudioClip to:_renamedFile];
}

- (BOOL)renameFileFrom:(NSString*)oldName to:(NSString *)newName
{
    NSString *oldPath = [_recordingPath stringByAppendingPathComponent:oldName];
    NSString *newPath = [_recordingPath stringByAppendingPathComponent:newName];
    
    NSError *error = nil;
    
    if (![[NSFileManager defaultManager] moveItemAtPath:oldPath toPath:newPath error:&error])
    {
        //NSLog(@"Failed to move '%@' to '%@': %@", oldPath, newPath, [error localizedDescription]);
        return NO;
    }
    
    //NSLog(@"file was renamed, bud!");
    [self listFiles];
    [NSTimer scheduledTimerWithTimeInterval:0.3
                                     target:self
                                   selector:@selector(reloadTableView)
                                   userInfo:nil
                                    repeats:NO];
    return YES;
}

-(void) checkIfFilenameIsIdentical {
    
    _directoryContent = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_recordingPath error:NULL];
    
    NSPredicate* predicate = [NSPredicate predicateWithFormat:@"SELF CONTAINS %@",_renamedFile];
    
    if ([predicate evaluateWithObject:_directoryContent])
    {
        //NSLog(@"There is an existing audio file named, %@. Would you like to replace it?", _renamedFile);
        [self overwriteFileWarning:self];
    } else {
        //NSLog(@"No matches");
        [self fileRenamed];
    }
    
}

- (void) overwriteFileWarning:(id)sender {
    
    UIAlertController *alertController = [UIAlertController
                                          alertControllerWithTitle:@"A file with the same name already exists."
                                          message:@"Please enter a different name."
                                          preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction
                               actionWithTitle:NSLocalizedString(@"OK", @"OK action")
                               style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action)
                               {
                                   [self renameFileAction];
                                   
                               }];
    
    UIAlertAction *cancelAction = [UIAlertAction
                                   actionWithTitle:NSLocalizedString(@"Cancel", @"Cancel action")
                                   style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction *action)
                                   {
                                       //NSLog(@"Cancel action");
                                       
                                   }];
    
    [alertController addAction:okAction];
    [alertController addAction:cancelAction];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

-(void) checkIfFileExists {
    
    NSString *path;
    
    path = [_recordingPath stringByAppendingPathComponent:_currentAudioClip];
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
    {
        //NSLog(@"This file exists");
    } else {
        //NSLog(@"This file does not exist");
    }
}

@end