using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class AddUserToADStudentGroup : AccountAction
    {
        public AddUserToADStudentGroup() : base(AccountActionType.AddToADStudentGroup,
            "Voeg de leerling toe aan de AD groep Students",
            "Wanneer de leerling geen lid is van deze group, is de toegang van het account beperkt.",
            true, true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await linkedAccount.directoryAccount.AddToGroup("CN=Students,OU=Security Groups,DC=sanctamaria-aarschot,DC=be");
        }

        public static void ApplyIfNeeded(LinkedAccount account)
        {
            if (!account.directoryAccount.Groups.Contains("CN=Students,OU=Security Groups,DC=sanctamaria-aarschot,DC=be"))
            {
                account.DirectoryStatusIcon = "AlertCircleOutline";
                account.DirectoryStatusColor = "Orange";
                account.Actions.Add(new AddUserToADStudentGroup());
                account.AccountOK = false;
            }
        }
    }
}
