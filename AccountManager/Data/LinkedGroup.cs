using AccountManager.Action;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public class LinkedGroup
    {
        public AccountApi.Wisa.ClassGroup wisaGroup = null;
        public AccountApi.Directory.ClassGroup directoryGroup = null;
        public AccountApi.Smartschool.Group smartschoolGroup = null;

        public List<GroupAction> Actions = new List<GroupAction>();

        public LinkedGroup(AccountApi.Wisa.ClassGroup group)
        {
            wisaGroup = group;
        }

        public LinkedGroup(AccountApi.Directory.ClassGroup group)
        {
            directoryGroup = group;
        }

        public LinkedGroup(AccountApi.Smartschool.Group group)
        {
            smartschoolGroup = group;
        }

        public string Name
        {
            get
            {
                if (wisaGroup != null) return wisaGroup.Name;
                if (directoryGroup != null) return directoryGroup.Name;
                if (smartschoolGroup != null) return smartschoolGroup.Name;
                return "Group Name Error";
            }
        }

        private bool groupOK;
        public bool GroupOK => groupOK;

        public void Compare()
        {
            groupOK = false;

            // first set a base color and icon depending on whether or not the group exists
            if (wisaGroup == null)
            {
                wisaStatusIcon = "AlertCircleOutline";
                wisaStatusColor = "DarkRed";
            }
            else
            {
                wisaStatusIcon = "CheckboxMarkedCircleOutline";
                wisaStatusColor = "DarkGreen";
            }

            if (smartschoolGroup == null)
            {
                smartschoolStatusIcon = "AlertCircleOutline";
                smartschoolStatusColor = "DarkRed";
            }
            else
            {
                smartschoolStatusIcon = "CheckboxMarkedCircleOutline";
                smartschoolStatusColor = "DarkGreen";
            }

            if (directoryGroup == null)
            {
                directoryStatusIcon = "AlertCircleOutline";
                directoryStatusColor = "DarkRed";
            }
            else
            {
                directoryStatusIcon = "CheckboxMarkedCircleOutline";
                directoryStatusColor = "DarkGreen";
            }

            // set action for non existing groups
            if (wisaGroup != null && directoryGroup != null && smartschoolGroup != null)
            {
                groupOK = FindActionsForSmartschool();
            } else
            {  
                FindActionsForMissingGroups();
                groupOK = false;
            }
            

        }

        private void FindActionsForMissingGroups()
        {
            if(wisaGroup != null)
            {
                if(directoryGroup == null && smartschoolGroup == null)
                {
                    Actions.Add(new DoNotImportFromWisa());
                }
                if(smartschoolGroup == null)
                {
                    if (wisaGroup.ContainsStudents())
                    {
                        // add to smartschool
                        Actions.Add(new AddClassGroupToSmartschool());
                    } else
                    {
                        // cannot add an empty group to smartschool
                        Actions.Add(new EmptyClassGroupToSmartschool());
                    }
                }

                if(directoryGroup == null)
                {
                    Actions.Add(new AddClassGroupToDirectory());
                }
            }
            // check if group only exists in directory
            else if(directoryGroup != null && wisaGroup == null && smartschoolGroup == null)
            {
                if(AccountApi.Directory.AccountManager.ContainsStudents(directoryGroup)) {
                    Actions.Add(new RemoveDirectoryClassGroup());
                } else
                {
                    Actions.Add(new RemoveEmptyDirectoryClassGroup());
                }
            }
            // 
            else if (smartschoolGroup != null && wisaGroup == null && directoryGroup == null)
            {
                Actions.Add(new DoNotImportClassGroupFromSmartschool());
            }
        }

        private bool FindActionsForSmartschool()
        {
            var action = new ModifySmartschoolData();

            if (wisaGroup.SchoolCode != smartschoolGroup.InstituteNumber) action.List.Add(ModifySmartschoolData.Fields.Instellingsnummer);
            if (smartschoolGroup.Name != smartschoolGroup.Untis) action.List.Add(ModifySmartschoolData.Fields.UntisID);
            if (smartschoolGroup.Description != wisaGroup.Description) action.List.Add(ModifySmartschoolData.Fields.Beschrijving);

            if(action.List.Count > 0)
            {
                smartschoolStatusIcon = "CircleEditOutline";
                smartschoolStatusColor = "Chocolate";
                Actions.Add(action);
                return false;
            } else
            {
                return true;
            }
        }

        public bool WisaLinked => wisaGroup != null;
        public bool SmartschoolLinked => smartschoolGroup != null;
        public bool DirectoryLinked => directoryGroup != null;

        private string wisaStatusIcon;
        public string WisaStatusIcon => wisaStatusIcon;

        private string wisaStatusColor;
        public string WisaStatusColor => wisaStatusColor;

        private string directoryStatusIcon;
        public string DirectoryStatusIcon => directoryStatusIcon;

        private string directoryStatusColor;
        public string DirectoryStatusColor => directoryStatusColor;

        private string smartschoolStatusIcon;
        public string SmartschoolStatusIcon => smartschoolStatusIcon;

        private string smartschoolStatusColor;
        public string SmartschoolStatusColor => smartschoolStatusColor;
      
    }
}
