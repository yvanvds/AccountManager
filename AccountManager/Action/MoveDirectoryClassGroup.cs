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
            true)
        { }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            await AccountApi.Directory.AccountManager.MoveStudentToClass(linkedAccount.directoryAccount, linkedAccount.wisaAccount.ClassGroup);
        }
    }
}
