using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class RemoveEmptyDirectoryClassGroup : GroupAction
    {
        public override async Task Apply(LinkedGroup linkedGroup)
        {
            InProgress.Value = true;
            await AccountApi.Directory.ClassGroupManager.Delete(linkedGroup.directoryGroup);
            Data.Instance.SaveADGroupsToFile();
            InProgress.Value = false;
        }

        public RemoveEmptyDirectoryClassGroup() : base(
            "Lege Active Directory Klas Verwijderen",
            "Deze klas is leeg en bestaat enkel in Active Directory. " +
            "De klas kan verwijderd worden.",
            true)
        {}
    }
}
