using AccountManager.Action;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public class LinkedAccount
    {
        public AccountApi.Wisa.Student wisaAccount = null;
        public AccountApi.Directory.Account directoryAccount = null;
        public AccountApi.Smartschool.Account smartschoolAccount = null;
        public AccountApi.Google.Account googleAccount = null;

        public List<AccountAction> Actions = new List<AccountAction>();

        public LinkedAccount(AccountApi.Wisa.Student account)
        {
            wisaAccount = account;
        }

        public LinkedAccount(AccountApi.Directory.Account account)
        {
            directoryAccount = account;
        }

        public LinkedAccount(AccountApi.Smartschool.Account account)
        {
            smartschoolAccount = account;
        }

        public LinkedAccount(AccountApi.Google.Account account)
        {
            googleAccount = account;
        }

        public string UID
        {
            get
            {
                if (directoryAccount != null) return directoryAccount.UID;
                if (smartschoolAccount != null) return smartschoolAccount.UID;
                if (googleAccount != null) return googleAccount.UID;
                if (wisaAccount != null) return wisaAccount.WisaID;
                return "No User ID";
            }
        }

        public string Name
        {
            get
            {
                if (wisaAccount != null) return wisaAccount.Name + " " + wisaAccount.FirstName;
                if (smartschoolAccount != null) return smartschoolAccount.SurName + " " + smartschoolAccount.GivenName;
                if (directoryAccount != null) return directoryAccount.FullName;
                if (googleAccount != null) return googleAccount.FullName;
                return "No User Name";
            }
        }

        public string ClassGroup
        {
            get
            {
                if (wisaAccount != null) return wisaAccount.ClassGroup;
                if (directoryAccount != null) return directoryAccount.ClassGroup;
                if (smartschoolAccount != null) return smartschoolAccount.Group;
                return "Google";
            }
        }

        public bool AccountOK { get; set; }

        public void Compare()
        {
            AccountOK = false;

            if (wisaAccount == null)
            {
                wisaStatusIcon = "AlertCircleOutline";
                wisaStatusColor = "DarkRed";
            }
            else
            {
                wisaStatusIcon = "CheckboxMarkedCircleOutline";
                wisaStatusColor = "DarkGreen";
            }

            if (smartschoolAccount == null)
            {
                smartschoolStatusIcon = "AlertCircleOutline";
                smartschoolStatusColor = "DarkRed";
            }
            else
            {
                smartschoolStatusIcon = "CheckboxMarkedCircleOutline";
                smartschoolStatusColor = "DarkGreen";
            }

            if (directoryAccount == null)
            {
                directoryStatusIcon = "AlertCircleOutline";
                directoryStatusColor = "DarkRed";
            }
            else
            {
                directoryStatusIcon = "CheckboxMarkedCircleOutline";
                directoryStatusColor = "DarkGreen";
            }

            if (googleAccount == null)
            {
                googleStatusIcon = "AlertCircleOutline";
                googleStatusColor = "DarkRed";
            }
            else
            {
                googleStatusIcon = "CheckboxMarkedCircleOutline";
                googleStatusColor = "DarkGreen";
            }

            

            if (wisaAccount != null && directoryAccount != null && smartschoolAccount != null)// don't include google anymore && googleAccount != null)
            {
                AccountOK = true;
                FindActionsForLinkedAccounts();
            } else
            {
                FindActionsForMissingAccounts();
                AccountOK = false;
            }

            if(wisaAccount != null && directoryAccount !=  null)
            {
                if(wisaAccount.ClassGroup != directoryAccount.ClassGroup)
                {
                    Actions.Add(new MoveDirectoryClassGroup());
                    directoryStatusIcon = "AlertCircleOutline";
                    directoryStatusColor = "Orange";
                    AccountOK = false;
                }
            }

            if (wisaAccount != null && smartschoolAccount != null)
            {          
                if(!wisaAccount.ClassGroup.Contains("ANS") && !wisaAccount.ClassGroup.Contains("BNS") && wisaAccount.ClassGroup != smartschoolAccount.Group)
                {
                    Actions.Add(new MoveToSmartschoolClassGroup());
                    smartschoolStatusIcon = "AlertCircleOutline";
                    smartschoolStatusColor = "Orange";
                    AccountOK = false;
                }
            }

            if(directoryAccount != null)
            {
                var action = new ModifyDirectoryData();
                if (directoryAccount.CN != directoryAccount.DesiredCN())
                {
                    action.List.Add(ModifyDirectoryData.Fields.CommonName);
                }

                if(action.List.Count > 0)
                {
                    directoryStatusIcon = "AlertCircleOutline";
                    directoryStatusIcon = "Orange";
                    Actions.Add(action);
                    AccountOK = false;
                }
            }
        }

        private void FindActionsForMissingAccounts()
        {
            // if account is only on google, suggest removal
            if (wisaAccount == null && directoryAccount == null && smartschoolAccount == null && googleAccount != null)
            {
                Actions.Add(new RemoveAccountFromGoogle());
            }

            // if account is only on directory, suggest removal
            else
            {
                if (wisaAccount == null && directoryAccount != null)
                {
                    Actions.Add(new RemoveAccountFromDirectory());
                }
                // if account is only on smartschool, suggest removal or diable
                if (wisaAccount == null && smartschoolAccount != null)
                {
                    if (smartschoolAccount.Status == "actief") {
                        Actions.Add(new UnregisterSmartschoolAccount());
                    } else
                    {
                        MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Smartschool, "niet actief");
                    }
                    Actions.Add(new DeleteSmartschoolAccount(smartschoolAccount.Status != "actief"));

                }
            }

            // if account is only on wisa, add on directory and smartschool
            if (wisaAccount != null && directoryAccount == null && smartschoolAccount == null)
            {
                Actions.Add(new AddAccountToDirectoryAndSmartschool());

            // if account exists on wisa and directory, add to smartschool
            } else if (wisaAccount != null && directoryAccount != null && smartschoolAccount == null)
            {
                Actions.Add(new AddAccountToSmartschool());
            }
        }

        // searches for differences between accounts if they all exist
        void FindActionsForLinkedAccounts()
        {
            ModifySmartschoolStudentAddress.ApplyIfNeeded(this);
            AddUserToADStudentGroup.ApplyIfNeeded(this);
            ModifyStudentHomeDir.ApplyIfNeeded(this);
            ModifyAccountID.ApplyIfNeeded(this);
            ModifySmartschoolStemID.ApplyIfNeeded(this);
        }

        

        public AccountAction GetSameAction(AccountAction action)
        {
            foreach(var act in Actions)
            {
                if(act.AccountActionType == action.AccountActionType)
                {
                    return act;
                }
            }
            return null;
        }

        public bool WisaLinked => wisaAccount != null;
        public bool SmartschoolLinked => smartschoolAccount != null;
        public bool DirectoryLinked => directoryAccount != null;
        public bool GoogleLinked => googleAccount != null;

        private string wisaStatusIcon;
        public string WisaStatusIcon {
            get => wisaStatusIcon;
            set => wisaStatusIcon = value;
        }

        private string wisaStatusColor;
        public string WisaStatusColor
        {
            get => wisaStatusColor;
            set => wisaStatusColor = value;
        }

        private string directoryStatusIcon;
        public string DirectoryStatusIcon
        {
            get => directoryStatusIcon;
            set => directoryStatusIcon = value;
        }

        private string directoryStatusColor;
        public string DirectoryStatusColor
        {
            get => directoryStatusColor;
            set => directoryStatusColor = value;
        }

        private string smartschoolStatusIcon;
        public string SmartschoolStatusIcon
        {
            get => smartschoolStatusIcon;
            set => smartschoolStatusIcon = value;
        }

        private string smartschoolStatusColor;
        public string SmartschoolStatusColor
        {
            get => smartschoolStatusColor;
            set => smartschoolStatusColor = value;
        }

        private string googleStatusIcon;
        public string GoogleStatusIcon
        {
            get => googleStatusIcon;
            set => googleStatusIcon = value;
        }

        private string googleStatusColor;
        public string GoogleStatusColor
        {
            get => googleStatusColor;
            set => googleStatusColor = value;
        }
    }
}
