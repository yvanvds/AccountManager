using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class MoveDirectoryClassGroup : AccountAction
    {
        public MoveDirectoryClassGroup() : base(
            AccountActionType.MoveDirectoryClassGroup,
            "Wijzig Klas in Active Directory",
            "De klas van dit account komt niet overeen met de gegevens in Wisa",
            true, true)
        { }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            bool result = await AccountApi.Directory.AccountManager.MoveStudentToClass(linkedAccount.directoryAccount, linkedAccount.wisaAccount.ClassGroup);
            if(result)
            {
                MainWindow.Instance.Log.AddMessage(AccountApi.Origin.Directory, linkedAccount.wisaAccount.FullName + " moved to " + linkedAccount.wisaAccount.ClassGroup);
            } else
            {
                MainWindow.Instance.Log.AddError(AccountApi.Origin.Directory, "Failed to move " + linkedAccount.wisaAccount.FullName + " to " + linkedAccount.wisaAccount.ClassGroup);
            }
        }
    }
}
