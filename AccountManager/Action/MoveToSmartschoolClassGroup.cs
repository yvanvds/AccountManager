using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class MoveToSmartschoolClassGroup : AccountAction
    {
        public MoveToSmartschoolClassGroup() : base(
            "Wijzig Klas in Smartschool",
            "De klas van dit account komt niet overeen met de klas in Wisa",
            true)
        {

        }

        public async override Task Apply(LinkedAccount linkedAccount)
        {
            var group = AccountApi.Smartschool.GroupManager.Root.Find(linkedAccount.wisaAccount.ClassGroup);
            await AccountApi.Smartschool.GroupManager.MoveUserToClass(linkedAccount.smartschoolAccount, group, linkedAccount.wisaAccount.ClassChange);
        }
    }
}
